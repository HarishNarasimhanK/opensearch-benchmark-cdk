#!/usr/bin/env python3
"""
generate-comparison.py — Generates a single HTML file with Plotly charts
comparing Parquet vs Lucene vs ParquetLucene benchmark results.

Usage:
  python3 generate-comparison.py \
    --parquet-csv ~/benchmark-results/parquet/benchmark-*.csv \
    --lucene-csv ~/benchmark-results/lucene/benchmark-*.csv \
    --parquet-lucene-csv ~/benchmark-results/parquetLucene/benchmark-*.csv \
    --output ~/benchmark-comparison.html \
    --run-id run-20260503_193554

Reads the OSB CSV format (Metric,Task,Value,Unit) and produces:
  1. P50 service time comparison (grouped bar, only passing queries)
  2. Pass/fail heatmap (green/red grid per engine)
  3. Latency percentile spread (p50/p90/p99 grouped bars, passing-on-all)
  4. Latency scatter plot (Parquet vs Lucene p50, diagonal = equal)
  5. Indexing throughput comparison (docs/s from index-append task)
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


def get_metric(data, metric_name, task):
    """Get a metric value, return None if not found"""
    if data is None:
        return None
    return data.get((metric_name, task))


def js_array(values):
    """Convert a Python list to a JSON array string, handling None -> null correctly."""
    return json.dumps(values)


def build_all_query_names(pq_data, lu_data, pql_data=None):
    """Get the union of all normalized query names across engines."""
    pq_tasks = get_query_tasks(pq_data)
    lu_tasks = get_query_tasks(lu_data)
    pql_tasks = get_query_tasks(pql_data) if pql_data else []

    pq_norm = {normalize_task_name(t): t for t in pq_tasks}
    lu_norm = {normalize_task_name(t): t for t in lu_tasks}
    pql_norm = {normalize_task_name(t): t for t in pql_tasks}

    all_queries = sorted(set(pq_norm.keys()) | set(lu_norm.keys()) | set(pql_norm.keys()))
    common = sorted(set(pq_norm.keys()) & set(lu_norm.keys()))
    return all_queries, common, pq_norm, lu_norm, pql_norm


def is_passing(data, norm_map, q):
    """Check if a query passes (0% error rate) for a given engine."""
    if data is None or q not in norm_map:
        return False
    err = get_metric(data, 'error rate', norm_map[q])
    return err is not None and err == 0


def generate_html(pq_data, lu_data, run_id, output_path, pql_data=None):
    """Generate the comparison HTML with Plotly charts for 2 or 3 engines."""

    all_queries, common, pq_norm, lu_norm, pql_norm = build_all_query_names(pq_data, lu_data, pql_data)
    has_pql = pql_data is not None and len(pql_norm) > 0

    # Use common (pq & lu intersection) for the main comparison set
    # Include pql where it overlaps
    queries = common

    # --- Classify queries ---
    pq_passing_count = sum(1 for q in queries if is_passing(pq_data, pq_norm, q))
    lu_passing_count = sum(1 for q in queries if is_passing(lu_data, lu_norm, q))
    pql_passing_count = sum(1 for q in queries if is_passing(pql_data, pql_norm, q)) if has_pql else 0

    passing_all = [q for q in queries if is_passing(pq_data, pq_norm, q) and is_passing(lu_data, lu_norm, q)
                   and (not has_pql or is_passing(pql_data, pql_norm, q))]
    passing_pq_lu = [q for q in queries if is_passing(pq_data, pq_norm, q) and is_passing(lu_data, lu_norm, q)]

    # --- Chart 1: P50 Service Time (all queries, show bar only if passing) ---
    labels_latency = []
    pq_latency = []
    lu_latency = []
    pql_latency = []
    for q in queries:
        pq_pass = is_passing(pq_data, pq_norm, q)
        lu_pass = is_passing(lu_data, lu_norm, q)
        pql_pass = is_passing(pql_data, pql_norm, q) if has_pql else False
        if not pq_pass and not lu_pass and not pql_pass:
            continue
        labels_latency.append(q)
        pq_val = get_metric(pq_data, '50th percentile service time', pq_norm.get(q, ''))
        lu_val = get_metric(lu_data, '50th percentile service time', lu_norm.get(q, ''))
        pql_val = get_metric(pql_data, '50th percentile service time', pql_norm.get(q, '')) if has_pql else None
        pq_latency.append(round(pq_val, 2) if (pq_pass and pq_val is not None) else None)
        lu_latency.append(round(lu_val, 2) if (lu_pass and lu_val is not None) else None)
        pql_latency.append(round(pql_val, 2) if (pql_pass and pql_val is not None) else None)

    # --- Chart 2: Error Rate Heatmap ---
    heatmap_queries = queries
    heatmap_pq_err = []
    heatmap_lu_err = []
    heatmap_pql_err = []
    for q in heatmap_queries:
        pq_val = get_metric(pq_data, 'error rate', pq_norm.get(q, ''))
        lu_val = get_metric(lu_data, 'error rate', lu_norm.get(q, ''))
        pql_val = get_metric(pql_data, 'error rate', pql_norm.get(q, '')) if has_pql else None
        heatmap_pq_err.append(round(pq_val, 1) if pq_val is not None else 100)
        heatmap_lu_err.append(round(lu_val, 1) if lu_val is not None else 100)
        heatmap_pql_err.append(round(pql_val, 1) if pql_val is not None else 100)

    if has_pql:
        heatmap_z = [[p, l, pl] for p, l, pl in zip(heatmap_pq_err, heatmap_lu_err, heatmap_pql_err)]
        heatmap_x = ['Parquet', 'Lucene', 'ParquetLucene']
    else:
        heatmap_z = [[p, l] for p, l in zip(heatmap_pq_err, heatmap_lu_err)]
        heatmap_x = ['Parquet', 'Lucene']

    # --- Chart 3: Latency Percentiles (p50/p90/p99) for queries passing on pq & lu ---
    pct_labels = []
    pq_p50 = []; pq_p90 = []; pq_p99 = []
    lu_p50 = []; lu_p90 = []; lu_p99 = []
    pql_p50 = []; pql_p90 = []; pql_p99 = []
    for q in passing_pq_lu:
        pct_labels.append(q)
        pq_p50.append(round(get_metric(pq_data, '50th percentile service time', pq_norm[q]) or 0, 2))
        pq_p90.append(round(get_metric(pq_data, '90th percentile service time', pq_norm[q]) or 0, 2))
        pq_p99.append(round(get_metric(pq_data, '99th percentile service time', pq_norm[q]) or 0, 2))
        lu_p50.append(round(get_metric(lu_data, '50th percentile service time', lu_norm[q]) or 0, 2))
        lu_p90.append(round(get_metric(lu_data, '90th percentile service time', lu_norm[q]) or 0, 2))
        lu_p99.append(round(get_metric(lu_data, '99th percentile service time', lu_norm[q]) or 0, 2))
        if has_pql and q in pql_norm:
            pql_p50.append(round(get_metric(pql_data, '50th percentile service time', pql_norm[q]) or 0, 2))
            pql_p90.append(round(get_metric(pql_data, '90th percentile service time', pql_norm[q]) or 0, 2))
            pql_p99.append(round(get_metric(pql_data, '99th percentile service time', pql_norm[q]) or 0, 2))
        else:
            pql_p50.append(None); pql_p90.append(None); pql_p99.append(None)

    # --- Chart 4: Scatter — Parquet vs Lucene p50 latency ---
    scatter_lu = []
    scatter_pq = []
    scatter_labels = []
    for q in passing_pq_lu:
        pq_val = get_metric(pq_data, '50th percentile service time', pq_norm[q])
        lu_val = get_metric(lu_data, '50th percentile service time', lu_norm[q])
        if pq_val is not None and lu_val is not None:
            scatter_lu.append(round(lu_val, 2))
            scatter_pq.append(round(pq_val, 2))
            scatter_labels.append(q)

    # --- Chart 5: Indexing Throughput (docs/s from index-append) ---
    ingest_metrics = {}
    for engine_name, data in [('Parquet', pq_data), ('Lucene', lu_data), ('ParquetLucene', pql_data)]:
        if data is None:
            continue
        throughput = get_metric(data, 'Median Throughput', 'index-append')
        total_time = get_metric(data, '100th percentile service time', 'index-append')
        ingest_metrics[engine_name] = {
            'throughput': round(throughput, 1) if throughput else 0,
            'total_time_s': round(total_time / 1000, 1) if total_time else 0,
        }

    ingest_engines = [e for e in ['Parquet', 'Lucene', 'ParquetLucene'] if e in ingest_metrics]
    ingest_throughputs = [ingest_metrics[e]['throughput'] for e in ingest_engines]
    ingest_colors = {'Parquet': '#FF6B35', 'Lucene': '#004E89', 'ParquetLucene': '#2ECC71'}
    ingest_bar_colors = [ingest_colors.get(e, '#999') for e in ingest_engines]

    # --- Summary stats ---
    ratios = []
    for q in passing_pq_lu:
        pq_val = get_metric(pq_data, '50th percentile service time', pq_norm[q])
        lu_val = get_metric(lu_data, '50th percentile service time', lu_norm[q])
        if pq_val and lu_val and lu_val > 0:
            ratios.append(pq_val / lu_val)
    avg_ratio = sum(ratios) / len(ratios) if ratios else 0
    ratio_label = f"{avg_ratio:.1f}x" if avg_ratio > 0 else "N/A"

    pq_medians = sorted([get_metric(pq_data, '50th percentile service time', pq_norm[q]) or 0 for q in passing_pq_lu])
    lu_medians = sorted([get_metric(lu_data, '50th percentile service time', lu_norm[q]) or 0 for q in passing_pq_lu])
    pq_median_of_medians = pq_medians[len(pq_medians)//2] if pq_medians else 0
    lu_median_of_medians = lu_medians[len(lu_medians)//2] if lu_medians else 0

    # ParquetLucene summary card
    pql_summary = ""
    if has_pql:
        pql_summary = f"""
  <div class="card">
    <h3>ParquetLucene Queries</h3>
    <div class="value">{pql_passing_count} / {len(queries)} pass</div>
  </div>"""

    # --- Generate HTML ---
    pql_chart1_trace = ""
    if has_pql:
        pql_chart1_trace = f""",
  {{name: 'ParquetLucene', x: {js_array(labels_latency)}, y: {js_array(pql_latency)}, type: 'bar',
    marker: {{color: '#2ECC71'}},
    hovertemplate: '%{{x}}<br>ParquetLucene: %{{y:.2f}} ms<extra></extra>'}}"""

    pql_chart3_traces = ""
    if has_pql:
        pql_chart3_traces = f""",
  {{name: 'ParquetLucene p50', x: {js_array(pct_labels)}, y: {js_array(pql_p50)}, type: 'bar',
    marker: {{color: 'rgba(46,204,113,1.0)'}}, legendgroup: 'pql'}},
  {{name: 'ParquetLucene p90', x: {js_array(pct_labels)}, y: {js_array(pql_p90)}, type: 'bar',
    marker: {{color: 'rgba(46,204,113,0.6)'}}, legendgroup: 'pql'}},
  {{name: 'ParquetLucene p99', x: {js_array(pct_labels)}, y: {js_array(pql_p99)}, type: 'bar',
    marker: {{color: 'rgba(46,204,113,0.3)'}}, legendgroup: 'pql'}}"""

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
</style>
</head>
<body>
<h1>Parquet vs Lucene{' vs ParquetLucene' if has_pql else ''} — Benchmark Comparison</h1>
<p class="subtitle">Run ID: {run_id} | Common queries: {len(queries)} | Passing on Parquet & Lucene: {len(passing_pq_lu)}</p>

<div class="summary">
  <div class="card">
    <h3>Parquet Queries</h3>
    <div class="value">{pq_passing_count} / {len(queries)} pass</div>
  </div>
  <div class="card">
    <h3>Lucene Queries</h3>
    <div class="value">{lu_passing_count} / {len(queries)} pass</div>
  </div>{pql_summary}
  <div class="card">
    <h3>Avg Latency Ratio</h3>
    <div class="value">{ratio_label}</div>
    <div class="note">(Parquet / Lucene p50, queries passing on both)</div>
  </div>
  <div class="card">
    <h3>Median p50 Service Time</h3>
    <div class="value">PQ: {pq_median_of_medians:.1f}ms / LU: {lu_median_of_medians:.1f}ms</div>
    <div class="note">(queries passing on both)</div>
  </div>
</div>

<div class="legend">
  <strong>Reading the charts:</strong>
  Chart 1 shows p50 service time — bars only appear for engines where the query passed (0% error rate).
  Chart 2 is a pass/fail heatmap — green = 0% errors, red = 100% errors.
  Chart 3 shows p50/p90/p99 service time for queries passing on Parquet & Lucene.
  Chart 4 is a scatter: X = Lucene p50, Y = Parquet p50. Above diagonal = Parquet slower.
  Chart 5 shows indexing throughput (median docs/s during bulk ingest).
</div>

<div class="chart" id="chart1"></div>
<div class="chart" id="chart2"></div>
<div class="chart" id="chart3"></div>
<div class="chart" id="chart4"></div>
<div class="chart" id="chart5"></div>

<script>
// Chart 1: P50 Service Time
Plotly.newPlot('chart1', [
  {{name: 'Parquet', x: {js_array(labels_latency)}, y: {js_array(pq_latency)}, type: 'bar',
    marker: {{color: '#FF6B35'}},
    hovertemplate: '%{{x}}<br>Parquet: %{{y:.2f}} ms<extra></extra>'}},
  {{name: 'Lucene', x: {js_array(labels_latency)}, y: {js_array(lu_latency)}, type: 'bar',
    marker: {{color: '#004E89'}},
    hovertemplate: '%{{x}}<br>Lucene: %{{y:.2f}} ms<extra></extra>'}}{pql_chart1_trace}
], {{
  title: 'P50 Service Time per Query (ms) — Lower is Better<br><sub>Only queries with 0% error rate shown per engine</sub>',
  barmode: 'group', xaxis: {{tickangle: -45}}, yaxis: {{title: 'ms'}},
  height: 500, margin: {{b: 150}}
}});

// Chart 2: Error Rate Heatmap
Plotly.newPlot('chart2', [{{
  z: {js_array(heatmap_z)},
  x: {js_array(heatmap_x)},
  y: {js_array(list(heatmap_queries))},
  type: 'heatmap',
  colorscale: [[0, '#2ecc71'], [0.01, '#2ecc71'], [0.01, '#e74c3c'], [1, '#e74c3c']],
  showscale: false,
  xgap: 3, ygap: 2
}}], {{
  title: 'Query Pass/Fail Heatmap — Green = Pass, Red = Fail',
  xaxis: {{side: 'top', tickfont: {{size: 14}}}},
  yaxis: {{autorange: 'reversed', tickfont: {{size: 11}}, dtick: 1}},
  height: {max(400, len(heatmap_queries) * 22 + 100)},
  margin: {{l: 220, t: 80, r: 30, b: 30}}
}});

// Chart 3: Latency Percentiles (p50/p90/p99)
Plotly.newPlot('chart3', [
  {{name: 'Parquet p50', x: {js_array(pct_labels)}, y: {js_array(pq_p50)}, type: 'bar',
    marker: {{color: 'rgba(255,107,53,1.0)'}}, legendgroup: 'pq'}},
  {{name: 'Parquet p90', x: {js_array(pct_labels)}, y: {js_array(pq_p90)}, type: 'bar',
    marker: {{color: 'rgba(255,107,53,0.6)'}}, legendgroup: 'pq'}},
  {{name: 'Parquet p99', x: {js_array(pct_labels)}, y: {js_array(pq_p99)}, type: 'bar',
    marker: {{color: 'rgba(255,107,53,0.3)'}}, legendgroup: 'pq'}},
  {{name: 'Lucene p50', x: {js_array(pct_labels)}, y: {js_array(lu_p50)}, type: 'bar',
    marker: {{color: 'rgba(0,78,137,1.0)'}}, legendgroup: 'lu'}},
  {{name: 'Lucene p90', x: {js_array(pct_labels)}, y: {js_array(lu_p90)}, type: 'bar',
    marker: {{color: 'rgba(0,78,137,0.6)'}}, legendgroup: 'lu'}},
  {{name: 'Lucene p99', x: {js_array(pct_labels)}, y: {js_array(lu_p99)}, type: 'bar',
    marker: {{color: 'rgba(0,78,137,0.3)'}}, legendgroup: 'lu'}}{pql_chart3_traces}
], {{
  title: 'Service Time Percentiles — Queries Passing on Parquet & Lucene (ms)<br><sub>p50 / p90 / p99 per engine</sub>',
  barmode: 'group', xaxis: {{tickangle: -45}}, yaxis: {{title: 'ms'}},
  height: 550, margin: {{b: 150}}
}});

// Chart 4: Scatter — Parquet vs Lucene p50 latency
var maxVal = Math.max(...{js_array(scatter_pq)}, ...{js_array(scatter_lu)}, 1) * 1.1;
Plotly.newPlot('chart4', [
  {{name: 'Queries', x: {js_array(scatter_lu)}, y: {js_array(scatter_pq)},
    text: {js_array(scatter_labels)}, mode: 'markers+text', type: 'scatter',
    textposition: 'top right', textfont: {{size: 9, color: '#666'}},
    marker: {{size: 10, color: '#FF6B35', line: {{width: 1, color: '#004E89'}}}},
    hovertemplate: '%{{text}}<br>Lucene: %{{x:.2f}}ms<br>Parquet: %{{y:.2f}}ms<extra></extra>'
  }}
], {{
  title: 'Parquet vs Lucene — P50 Service Time Scatter<br><sub>Above diagonal = Parquet slower | Below = Parquet faster</sub>',
  xaxis: {{title: 'Lucene p50 (ms)', range: [0, maxVal]}},
  yaxis: {{title: 'Parquet p50 (ms)', range: [0, maxVal]}},
  shapes: [{{type: 'line', x0: 0, y0: 0, x1: maxVal, y1: maxVal,
    line: {{color: '#333', width: 1, dash: 'dash'}}}}],
  height: 550, margin: {{l: 80, r: 30, t: 80, b: 80}},
  showlegend: false
}});

// Chart 5: Indexing Throughput
Plotly.newPlot('chart5', [
  {{x: {js_array(ingest_engines)}, y: {js_array(ingest_throughputs)}, type: 'bar',
    marker: {{color: {js_array(ingest_bar_colors)}}},
    text: {js_array([f"{{v}} docs/s" for v in ingest_throughputs])},
    textposition: 'outside',
    hovertemplate: '%{{x}}<br>%{{y:.1f}} docs/s<extra></extra>'}}
], {{
  title: 'Indexing Throughput — Median docs/s during Bulk Ingest<br><sub>Higher is better. Measures how fast each engine ingests the ClickBench dataset.</sub>',
  yaxis: {{title: 'docs/s'}},
  height: 400, margin: {{b: 80}},
  showlegend: false
}});
</script>
</body>
</html>"""

    with open(output_path, 'w') as f:
        f.write(html)
    print(f"Dashboard written to: {output_path}")


def main():
    parser = argparse.ArgumentParser(description='Generate benchmark comparison HTML')
    parser.add_argument('--parquet-csv', required=True, help='Path to Parquet benchmark CSV')
    parser.add_argument('--lucene-csv', required=True, help='Path to Lucene benchmark CSV')
    parser.add_argument('--parquet-lucene-csv', default=None, help='Path to ParquetLucene benchmark CSV (optional)')
    parser.add_argument('--output', default='benchmark-comparison.html', help='Output HTML path')
    parser.add_argument('--run-id', default='unknown', help='Run ID for the title')
    args = parser.parse_args()

    if not os.path.exists(args.parquet_csv):
        print(f"Error: Parquet CSV not found: {args.parquet_csv}")
        sys.exit(1)
    if not os.path.exists(args.lucene_csv):
        print(f"Error: Lucene CSV not found: {args.lucene_csv}")
        sys.exit(1)

    pq_data = parse_csv(args.parquet_csv)
    lu_data = parse_csv(args.lucene_csv)

    print(f"Parquet: {len(pq_data)} metrics loaded")
    print(f"Lucene: {len(lu_data)} metrics loaded")

    pql_data = None
    if args.parquet_lucene_csv and os.path.exists(args.parquet_lucene_csv):
        pql_data = parse_csv(args.parquet_lucene_csv)
        print(f"ParquetLucene: {len(pql_data)} metrics loaded")

    generate_html(pq_data, lu_data, args.run_id, args.output, pql_data=pql_data)


if __name__ == '__main__':
    main()
