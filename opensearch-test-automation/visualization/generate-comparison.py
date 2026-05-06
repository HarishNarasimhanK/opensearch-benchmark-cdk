#!/usr/bin/env python3
"""
generate-comparison.py — Generates a single HTML file with 4 Plotly charts
comparing DataFusion vs Lucene benchmark results.

Usage:
  python3 generate-comparison.py \
    --datafusion-csv ~/benchmark-results/datafusion/benchmark-*.csv \
    --lucene-csv ~/benchmark-results/lucene/benchmark-*.csv \
    --output ~/benchmark-comparison.html \
    --run-id run-20260503_193554

Reads the OSB CSV format (Metric,Task,Value,Unit) and produces:
  1. P50 service time comparison (grouped bar, only passing queries)
  2. Pass/fail heatmap (green/red grid per engine)
  3. Latency percentile spread (p50/p90/p99 grouped bars, passing-on-both)
  4. Latency scatter plot (DataFusion vs Lucene p50, diagonal = equal)
"""

import argparse
import csv
import json
import sys
import os

def parse_csv(filepath):
    """Parse OSB CSV into a dict: {(metric_name, task): value}"""
    data = {}
    with open(filepath, 'r') as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) < 3 or row[0] == 'Metric':
                continue
            metric, task, value, *rest = row
            if task and value:
                try:
                    data[(metric.strip(), task.strip())] = float(value)
                except ValueError:
                    pass
    return data

def get_query_tasks(data):
    """Extract query task names (q01-..., dsl-q01-...) excluding index-append, flush-index"""
    tasks = set()
    for (metric, task) in data:
        if task and ('q0' in task or 'q1' in task or 'q2' in task or 'q3' in task or 'q4' in task):
            tasks.add(task)
    return sorted(tasks)

def normalize_task_name(task):
    """Remove engine prefix for comparison: dsl-q01-count-all -> q01-count-all"""
    if task.startswith('dsl-'):
        return task[4:]
    return task

def build_comparison_data(df_data, lu_data):
    """Build aligned comparison data for common queries"""
    df_tasks = get_query_tasks(df_data)
    lu_tasks = get_query_tasks(lu_data)

    lu_norm = {normalize_task_name(t): t for t in lu_tasks}
    df_norm = {normalize_task_name(t): t for t in df_tasks}

    common = sorted(set(df_norm.keys()) & set(lu_norm.keys()))
    return common, df_norm, lu_norm

def get_metric(data, metric_name, task):
    """Get a metric value, return None if not found"""
    return data.get((metric_name, task))

def js_array(values):
    """Convert a Python list to a JSON array string, handling None -> null correctly."""
    return json.dumps(values)

def generate_html(df_data, lu_data, run_id, output_path):
    """Generate the comparison HTML with Plotly charts"""

    common, df_norm, lu_norm = build_comparison_data(df_data, lu_data)

    # Classify queries
    passing_both = []
    passing_df_only = []
    passing_lu_only = []
    failing_both = []
    for q in common:
        df_err = get_metric(df_data, 'error rate', df_norm[q])
        lu_err = get_metric(lu_data, 'error rate', lu_norm[q])
        df_pass = (df_err is not None and df_err == 0)
        lu_pass = (lu_err is not None and lu_err == 0)
        if df_pass and lu_pass:
            passing_both.append(q)
        elif df_pass:
            passing_df_only.append(q)
        elif lu_pass:
            passing_lu_only.append(q)
        else:
            failing_both.append(q)

    # --- Chart 1: P50 Service Time — only queries passing on at least one engine ---
    # Show bars only for the engine that passed. Errored engine gets no bar (null).
    labels_latency = []
    df_latency = []
    lu_latency = []
    for q in common:
        df_err = get_metric(df_data, 'error rate', df_norm[q])
        lu_err = get_metric(lu_data, 'error rate', lu_norm[q])
        df_pass = (df_err is not None and df_err == 0)
        lu_pass = (lu_err is not None and lu_err == 0)
        if not df_pass and not lu_pass:
            continue  # skip queries that fail on both — nothing to show
        df_val = get_metric(df_data, '50th percentile service time', df_norm[q])
        lu_val = get_metric(lu_data, '50th percentile service time', lu_norm[q])
        labels_latency.append(q)
        df_latency.append(round(df_val, 2) if (df_pass and df_val is not None) else None)
        lu_latency.append(round(lu_val, 2) if (lu_pass and lu_val is not None) else None)

    # --- Chart 2: Error Rate Heatmap ---
    # Binary pass/fail data is best shown as a heatmap — compact and scannable.
    # Rows = queries (Y-axis), Columns = [DataFusion, Lucene] (X-axis)
    # Color: 0 = pass (green), 100 = fail (red)
    heatmap_queries = []
    heatmap_df_err = []
    heatmap_lu_err = []
    for q in common:
        df_val = get_metric(df_data, 'error rate', df_norm[q])
        lu_val = get_metric(lu_data, 'error rate', lu_norm[q])
        heatmap_queries.append(q)
        heatmap_df_err.append(round(df_val , 1) if df_val is not None else 0)
        heatmap_lu_err.append(round(lu_val , 1) if lu_val is not None else 0)
    # Plotly heatmap z is [rows][cols] — each row is a query, cols are [DataFusion, Lucene]
    heatmap_z = [[d, l] for d, l in zip(heatmap_df_err, heatmap_lu_err)]
    # Custom text for hover
    heatmap_text = [
        [f"{q}: DataFusion {'PASS' if d == 0 else f'FAIL ({d}%)'}",
         f"{q}: Lucene {'PASS' if l == 0 else f'FAIL ({l}%)'}"]
        for q, d, l in zip(heatmap_queries, heatmap_df_err, heatmap_lu_err)
    ]

    # --- Chart 3: Latency Percentiles (p50/p90/p99) for queries passing on both ---
    pct_labels = []
    df_p50 = []; df_p90 = []; df_p99 = []
    lu_p50 = []; lu_p90 = []; lu_p99 = []
    for q in passing_both:
        pct_labels.append(q)
        df_p50.append(round(get_metric(df_data, '50th percentile service time', df_norm[q]) or 0, 2))
        df_p90.append(round(get_metric(df_data, '90th percentile service time', df_norm[q]) or 0, 2))
        df_p99.append(round(get_metric(df_data, '99th percentile service time', df_norm[q]) or 0, 2))
        lu_p50.append(round(get_metric(lu_data, '50th percentile service time', lu_norm[q]) or 0, 2))
        lu_p90.append(round(get_metric(lu_data, '90th percentile service time', lu_norm[q]) or 0, 2))
        lu_p99.append(round(get_metric(lu_data, '99th percentile service time', lu_norm[q]) or 0, 2))

    # --- Chart 4: Scatter — DataFusion vs Lucene p50 latency ---
    # Each dot is a query. X = Lucene p50, Y = DataFusion p50.
    # Dots above the diagonal = DataFusion slower. Dots below = DataFusion faster.
    scatter_lu = []
    scatter_df = []
    scatter_labels = []
    for q in passing_both:
        df_val = get_metric(df_data, '50th percentile service time', df_norm[q])
        lu_val = get_metric(lu_data, '50th percentile service time', lu_norm[q])
        if df_val is not None and lu_val is not None:
            scatter_lu.append(round(lu_val, 2))
            scatter_df.append(round(df_val, 2))
            scatter_labels.append(q)

    # --- Chart 5: Mean Throughput (achieved ops/s) for queries passing on both ---
    tp_labels = []
    df_tp = []
    lu_tp = []
    for q in passing_both:
        df_val = get_metric(df_data, 'Mean Throughput', df_norm[q])
        lu_val = get_metric(lu_data, 'Mean Throughput', lu_norm[q])
        if df_val is not None or lu_val is not None:
            tp_labels.append(q)
            df_tp.append(round(df_val, 2) if df_val is not None else 0)
            lu_tp.append(round(lu_val, 2) if lu_val is not None else 0)

    # --- Summary stats ---
    df_passing = len(passing_both) + len(passing_df_only)
    lu_passing = len(passing_both) + len(passing_lu_only)

    # Avg latency ratio: only for queries passing on both
    ratios = []
    for q in passing_both:
        df_val = get_metric(df_data, '50th percentile service time', df_norm[q])
        lu_val = get_metric(lu_data, '50th percentile service time', lu_norm[q])
        if df_val and lu_val and lu_val > 0:
            ratios.append(df_val / lu_val)
    avg_ratio = sum(ratios) / len(ratios) if ratios else 0
    ratio_label = f"{avg_ratio:.1f}x" if avg_ratio > 0 else "N/A"
    ratio_note = "(DataFusion / Lucene p50 service time)" if avg_ratio > 0 else ""

    # Median latency for each engine (passing-on-both queries only)
    df_medians = sorted([get_metric(df_data, '50th percentile service time', df_norm[q]) or 0 for q in passing_both])
    lu_medians = sorted([get_metric(lu_data, '50th percentile service time', lu_norm[q]) or 0 for q in passing_both])
    df_median_of_medians = df_medians[len(df_medians)//2] if df_medians else 0
    lu_median_of_medians = lu_medians[len(lu_medians)//2] if lu_medians else 0

    # --- Generate HTML ---
    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Benchmark Comparison — {run_id}</title>
<script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 20px; background: #fafafa; }}
  h1 {{ color: #333; margin-bottom: 5px; }}
  .subtitle {{ color: #666; margin-bottom: 30px; }}
  .chart {{ background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 30px; padding: 15px; }}
  .summary {{ display: flex; gap: 20px; margin-bottom: 30px; flex-wrap: wrap; }}
  .card {{ background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); padding: 20px; flex: 1; min-width: 200px; }}
  .card h3 {{ margin: 0 0 5px 0; color: #666; font-size: 14px; }}
  .card .value {{ font-size: 28px; font-weight: bold; color: #333; }}
  .card .note {{ font-size: 12px; color: #999; margin-top: 4px; }}
  .legend {{ background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); padding: 15px; margin-bottom: 30px; font-size: 13px; color: #555; }}
  .legend strong {{ color: #333; }}
</style>
</head>
<body>
<h1>DataFusion vs Lucene — Benchmark Comparison</h1>
<p class="subtitle">Run ID: {run_id} | Common queries: {len(common)} | Passing on both: {len(passing_both)}</p>

<div class="summary">
  <div class="card">
    <h3>DataFusion Queries</h3>
    <div class="value">{df_passing} / {len(common)} pass</div>
  </div>
  <div class="card">
    <h3>Lucene Queries</h3>
    <div class="value">{lu_passing} / {len(common)} pass</div>
  </div>
  <div class="card">
    <h3>Avg Latency Ratio</h3>
    <div class="value">{ratio_label}</div>
    <div class="note">{ratio_note}</div>
  </div>
  <div class="card">
    <h3>Median p50 Service Time</h3>
    <div class="value">DF: {df_median_of_medians:.1f}ms / LU: {lu_median_of_medians:.1f}ms</div>
    <div class="note">(queries passing on both)</div>
  </div>
</div>

<div class="legend">
  <strong>Reading the charts:</strong>
  Chart 1 shows p50 service time — bars only appear for engines where the query passed (0% error rate).
  Missing bars mean that engine errored on that query.
  Chart 2 is a pass/fail heatmap — green = 0% errors, red = 100% errors. Scan vertically to see which queries each engine handles.
  Chart 3 shows p50/p90/p99 service time per engine for queries passing on both. Darker = lower percentile.
  Chart 4 is a scatter plot: each dot is a query, X = Lucene latency, Y = DataFusion latency. Dots above the diagonal line mean DataFusion is slower.
  Chart 5 shows mean throughput (achieved ops/s) per query — higher is better.
</div>

<div class="chart" id="chart1"></div>
<div class="chart" id="chart2"></div>
<div class="chart" id="chart3"></div>
<div class="chart" id="chart4"></div>
<div class="chart" id="chart5"></div>

<script>
// Chart 1: P50 Service Time (only passing queries get bars)
Plotly.newPlot('chart1', [
  {{name: 'DataFusion', x: {js_array(labels_latency)}, y: {js_array(df_latency)}, type: 'bar',
    marker: {{color: '#FF6B35'}},
    hovertemplate: '%{{x}}<br>DataFusion: %{{y:.2f}} ms<extra></extra>'}},
  {{name: 'Lucene', x: {js_array(labels_latency)}, y: {js_array(lu_latency)}, type: 'bar',
    marker: {{color: '#004E89'}},
    hovertemplate: '%{{x}}<br>Lucene: %{{y:.2f}} ms<extra></extra>'}}
], {{
  title: 'P50 Service Time per Query (ms) — Lower is Better<br><sub>Only queries with 0% error rate shown per engine. Missing bar = query errored.</sub>',
  barmode: 'group', xaxis: {{tickangle: -45}}, yaxis: {{title: 'ms'}},
  height: 500, margin: {{b: 150}}
}});

// Chart 2: Error Rate Heatmap (pass/fail grid)
Plotly.newPlot('chart2', [{{
  z: {js_array(heatmap_z)},
  x: ['DataFusion', 'Lucene'],
  y: {js_array(heatmap_queries)},
  text: {js_array(heatmap_text)},
  hovertemplate: '%{{text}}<extra></extra>',
  type: 'heatmap',
  colorscale: [[0, '#2ecc71'], [0.01, '#2ecc71'], [0.01, '#e74c3c'], [1, '#e74c3c']],
  showscale: false,
  xgap: 3, ygap: 2
}}], {{
  title: 'Query Pass/Fail Heatmap — Green = Pass (0% errors), Red = Fail',
  xaxis: {{side: 'top', tickfont: {{size: 14}}}},
  yaxis: {{autorange: 'reversed', tickfont: {{size: 11}}, dtick: 1}},
  height: {max(400, len(heatmap_queries) * 22 + 100)},
  margin: {{l: 220, t: 80, r: 30, b: 30}}
}});

// Chart 3: Latency Percentiles (p50/p90/p99) — queries passing on both
Plotly.newPlot('chart3', [
  {{name: 'DataFusion p50', x: {js_array(pct_labels)}, y: {js_array(df_p50)}, type: 'bar',
    marker: {{color: 'rgba(255,107,53,1.0)'}}, legendgroup: 'df'}},
  {{name: 'DataFusion p90', x: {js_array(pct_labels)}, y: {js_array(df_p90)}, type: 'bar',
    marker: {{color: 'rgba(255,107,53,0.6)'}}, legendgroup: 'df'}},
  {{name: 'DataFusion p99', x: {js_array(pct_labels)}, y: {js_array(df_p99)}, type: 'bar',
    marker: {{color: 'rgba(255,107,53,0.3)'}}, legendgroup: 'df'}},
  {{name: 'Lucene p50', x: {js_array(pct_labels)}, y: {js_array(lu_p50)}, type: 'bar',
    marker: {{color: 'rgba(0,78,137,1.0)'}}, legendgroup: 'lu'}},
  {{name: 'Lucene p90', x: {js_array(pct_labels)}, y: {js_array(lu_p90)}, type: 'bar',
    marker: {{color: 'rgba(0,78,137,0.6)'}}, legendgroup: 'lu'}},
  {{name: 'Lucene p99', x: {js_array(pct_labels)}, y: {js_array(lu_p99)}, type: 'bar',
    marker: {{color: 'rgba(0,78,137,0.3)'}}, legendgroup: 'lu'}}
], {{
  title: 'Service Time Percentiles — Queries Passing on Both Engines (ms)<br><sub>p50 / p90 / p99 per engine — p100 excluded to avoid cold-start outlier distortion</sub>',
  barmode: 'group', xaxis: {{tickangle: -45}}, yaxis: {{title: 'ms'}},
  height: 550, margin: {{b: 150}}
}});

// Chart 4: Scatter — DataFusion vs Lucene p50 latency
var maxVal = Math.max(...{js_array(scatter_df)}, ...{js_array(scatter_lu)}) * 1.1;
Plotly.newPlot('chart4', [
  {{name: 'Queries', x: {js_array(scatter_lu)}, y: {js_array(scatter_df)},
    text: {js_array(scatter_labels)}, mode: 'markers+text', type: 'scatter',
    textposition: 'top right', textfont: {{size: 9, color: '#666'}},
    marker: {{size: 10, color: '#FF6B35', line: {{width: 1, color: '#004E89'}}}},
    hovertemplate: '%{{text}}<br>Lucene: %{{x:.2f}}ms<br>DataFusion: %{{y:.2f}}ms<extra></extra>'
  }}
], {{
  title: 'DataFusion vs Lucene — P50 Service Time Scatter<br><sub>Above diagonal = DataFusion slower | Below = DataFusion faster | On line = equal</sub>',
  xaxis: {{title: 'Lucene p50 (ms)', range: [0, maxVal]}},
  yaxis: {{title: 'DataFusion p50 (ms)', range: [0, maxVal]}},
  shapes: [{{type: 'line', x0: 0, y0: 0, x1: maxVal, y1: maxVal,
    line: {{color: '#333', width: 1, dash: 'dash'}}}}],
  height: 550, margin: {{l: 80, r: 30, t: 80, b: 80}},
  showlegend: false
}});

// Chart 5: 100th Percentile Throughput (achieved ops/s)
Plotly.newPlot('chart5', [
  {{name: 'DataFusion', x: {js_array(tp_labels)}, y: {js_array(df_tp)}, type: 'bar',
    marker: {{color: '#FF6B35'}},
    hovertemplate: '%{{x}}<br>DataFusion: %{{y:.2f}} ops/s<extra></extra>'}},
  {{name: 'Lucene', x: {js_array(tp_labels)}, y: {js_array(lu_tp)}, type: 'bar',
    marker: {{color: '#004E89'}},
    hovertemplate: '%{{x}}<br>Lucene: %{{y:.2f}} ops/s<extra></extra>'}}
], {{
  title: 'Mean Throughput — Queries Passing on Both (ops/s) — Higher is Better<br><sub>Actual achieved query execution rate. Lower throughput = query took longer.</sub>',
  barmode: 'group', xaxis: {{tickangle: -45}}, yaxis: {{title: 'ops/s'}},
  height: 500, margin: {{b: 150}}
}});
</script>
</body>
</html>"""

    with open(output_path, 'w') as f:
        f.write(html)
    print(f"Dashboard written to: {output_path}")

def main():
    parser = argparse.ArgumentParser(description='Generate benchmark comparison HTML')
    parser.add_argument('--datafusion-csv', required=True, help='Path to DataFusion benchmark CSV')
    parser.add_argument('--lucene-csv', required=True, help='Path to Lucene benchmark CSV')
    parser.add_argument('--output', default='benchmark-comparison.html', help='Output HTML path')
    parser.add_argument('--run-id', default='unknown', help='Run ID for the title')
    args = parser.parse_args()

    if not os.path.exists(args.datafusion_csv):
        print(f"Error: DataFusion CSV not found: {args.datafusion_csv}")
        sys.exit(1)
    if not os.path.exists(args.lucene_csv):
        print(f"Error: Lucene CSV not found: {args.lucene_csv}")
        sys.exit(1)

    df_data = parse_csv(args.datafusion_csv)
    lu_data = parse_csv(args.lucene_csv)

    print(f"DataFusion: {len(df_data)} metrics loaded")
    print(f"Lucene: {len(lu_data)} metrics loaded")

    generate_html(df_data, lu_data, args.run_id, args.output)

if __name__ == '__main__':
    main()
