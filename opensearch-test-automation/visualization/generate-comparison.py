#!/usr/bin/env python3
"""
generate-comparison.py — Generates a single HTML dashboard comparing
Parquet vs Lucene vs ParquetLucene benchmark results.

Shows:
  - Grouped bar chart of p50 service time per query across all engines
  - Winner annotation per query (fastest engine highlighted)
  - Pass/fail summary table
  - Mean throughput comparison

Usage (backward compatible with run-all.sh):
  python3 generate-comparison.py \
    --parquet-csv ~/benchmark-results/parquet/benchmark-*.csv \
    --lucene-csv ~/benchmark-results/lucene/benchmark-*.csv \
    --parquet-lucene-csv ~/benchmark-results/parquetLucene/benchmark-*.csv \
    --output ~/benchmark-comparison.html \
    --run-id run-20260503_193554

Works with 2 engines (parquet + lucene) or 3 (+ parquetLucene).
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
    """Extract query task names (q01-..., dsl-q01-...) excluding index-append"""
    tasks = set()
    for (metric, task) in data:
        if task and ('q0' in task or 'q1' in task or 'q2' in task
                     or 'q3' in task or 'q4' in task):
            tasks.add(task)
    return sorted(tasks)


def normalize_task_name(task):
    """Remove engine prefix for comparison: dsl-q01-count-all -> q01-count-all"""
    if task.startswith('dsl-'):
        return task[4:]
    return task


def get_metric(data, metric_name, task):
    """Get a metric value, return None if not found"""
    return data.get((metric_name, task))


def js_array(values):
    """Convert a Python list to a JSON array string."""
    return json.dumps(values)


def build_query_map(data):
    """Build {normalized_name: original_task_name} for a dataset"""
    tasks = get_query_tasks(data)
    return {normalize_task_name(t): t for t in tasks}


def generate_html(engines, run_id, output_path):
    """
    engines: dict of {name: {data, color, query_map}}
    """
    # Find all common queries across all engines
    all_norm_sets = [set(e['query_map'].keys()) for e in engines.values()]
    all_queries = sorted(set.union(*all_norm_sets)) if all_norm_sets else []

    # --- Build per-query data ---
    query_data = []  # list of {query, engines: {name: {p50, error, throughput, passed}}}
    for q in all_queries:
        entry = {'query': q, 'engines': {}}
        for eng_name, eng in engines.items():
            if q not in eng['query_map']:
                entry['engines'][eng_name] = {'p50': None, 'error': None, 'throughput': None, 'passed': False}
                continue
            task = eng['query_map'][q]
            err = get_metric(eng['data'], 'error rate', task)
            p50 = get_metric(eng['data'], '50th percentile service time', task)
            tp = get_metric(eng['data'], 'Mean Throughput', task)
            passed = (err is not None and err == 0)
            entry['engines'][eng_name] = {
                'p50': round(p50, 2) if p50 is not None else None,
                'error': err,
                'throughput': round(tp, 2) if tp is not None else None,
                'passed': passed,
            }
        query_data.append(entry)

    # --- Determine winner per query (lowest p50 among passing engines) ---
    for entry in query_data:
        best_name = None
        best_p50 = float('inf')
        for eng_name, vals in entry['engines'].items():
            if vals['passed'] and vals['p50'] is not None and vals['p50'] < best_p50:
                best_p50 = vals['p50']
                best_name = eng_name
        entry['winner'] = best_name

    # --- Summary stats ---
    engine_names = list(engines.keys())
    pass_counts = {name: sum(1 for e in query_data if e['engines'][name]['passed']) for name in engine_names}
    win_counts = {name: sum(1 for e in query_data if e.get('winner') == name) for name in engine_names}
    total_queries = len(query_data)

    # --- Chart 1: P50 Service Time grouped bar ---
    chart1_labels = [e['query'] for e in query_data]
    chart1_traces = []
    for eng_name in engine_names:
        values = []
        for entry in query_data:
            v = entry['engines'][eng_name]
            values.append(v['p50'] if v['passed'] else None)
        chart1_traces.append({
            'name': eng_name,
            'values': values,
            'color': engines[eng_name]['color'],
        })

    # --- Winner annotations for chart 1 ---
    winner_annotations = []
    for i, entry in enumerate(query_data):
        if entry['winner']:
            # Find the winner's p50 value for annotation placement
            winner_p50 = entry['engines'][entry['winner']]['p50']
            winner_annotations.append({
                'x': entry['query'],
                'y': winner_p50,
                'text': '🏆',
                'showarrow': False,
                'yshift': 15,
                'font': {'size': 14},
            })

    # --- Chart 2: Throughput grouped bar ---
    chart2_labels = [e['query'] for e in query_data if any(
        e['engines'][n]['passed'] for n in engine_names)]
    chart2_traces = []
    for eng_name in engine_names:
        values = []
        for entry in query_data:
            if not any(entry['engines'][n]['passed'] for n in engine_names):
                continue
            v = entry['engines'][eng_name]
            values.append(v['throughput'] if v['passed'] else None)
        chart2_traces.append({
            'name': eng_name,
            'values': values,
            'color': engines[eng_name]['color'],
        })

    # --- Summary table HTML ---
    table_rows = ""
    for entry in query_data:
        cols = ""
        for eng_name in engine_names:
            v = entry['engines'][eng_name]
            if not v['passed']:
                cols += '<td class="fail">FAIL</td>'
            elif entry['winner'] == eng_name:
                cols += f'<td class="winner">{v["p50"]:.2f} ms 🏆</td>'
            else:
                cols += f'<td class="pass">{v["p50"]:.2f} ms</td>'
        table_rows += f"<tr><td class='query'>{entry['query']}</td>{cols}</tr>\n"

    # --- Build Plotly traces JS ---
    chart1_js_traces = ""
    for t in chart1_traces:
        chart1_js_traces += f"""  {{
    name: '{t["name"]}', x: {js_array(chart1_labels)}, y: {js_array(t["values"])},
    type: 'bar', marker: {{color: '{t["color"]}'}},
    hovertemplate: '%{{x}}<br>{t["name"]}: %{{y:.2f}} ms<extra></extra>'
  }},\n"""

    chart2_js_traces = ""
    for t in chart2_traces:
        chart2_js_traces += f"""  {{
    name: '{t["name"]}', x: {js_array(chart2_labels)}, y: {js_array(t["values"])},
    type: 'bar', marker: {{color: '{t["color"]}'}},
    hovertemplate: '%{{x}}<br>{t["name"]}: %{{y:.2f}} ops/s<extra></extra>'
  }},\n"""

    # --- Summary cards ---
    cards_html = ""
    for name in engine_names:
        color = engines[name]['color']
        cards_html += f"""
  <div class="card">
    <h3 style="color:{color}">{name}</h3>
    <div class="value">{pass_counts[name]} / {total_queries} pass</div>
    <div class="note">{win_counts[name]} wins (fastest p50)</div>
  </div>"""

    html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Benchmark Comparison — {run_id}</title>
<script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; margin: 20px; background: #fafafa; color: #333; }}
  h1 {{ margin-bottom: 5px; }}
  .subtitle {{ color: #666; margin-bottom: 30px; }}
  .chart {{ background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 30px; padding: 15px; }}
  .summary {{ display: flex; gap: 20px; margin-bottom: 30px; flex-wrap: wrap; }}
  .card {{ background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); padding: 20px; flex: 1; min-width: 180px; }}
  .card h3 {{ margin: 0 0 5px 0; font-size: 14px; }}
  .card .value {{ font-size: 28px; font-weight: bold; }}
  .card .note {{ font-size: 12px; color: #999; margin-top: 4px; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
  th {{ background: #f5f5f5; padding: 8px 12px; text-align: left; border-bottom: 2px solid #ddd; }}
  td {{ padding: 8px 12px; border-bottom: 1px solid #eee; }}
  .query {{ font-family: monospace; font-weight: 500; }}
  .pass {{ color: #27ae60; }}
  .fail {{ color: #e74c3c; font-weight: bold; }}
  .winner {{ color: #27ae60; font-weight: bold; background: #f0fff4; }}
  .results-table {{ background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 30px; padding: 15px; overflow-x: auto; }}
</style>
</head>
<body>
<h1>Benchmark Comparison — {run_id}</h1>
<p class="subtitle">Engines: {', '.join(engine_names)} | Total queries: {total_queries}</p>

<div class="summary">
{cards_html}
</div>

<div class="chart" id="chart1"></div>
<div class="chart" id="chart2"></div>

<div class="results-table">
<h3>Per-Query Results (P50 Service Time)</h3>
<table>
<thead><tr><th>Query</th>{''.join(f'<th>{n}</th>' for n in engine_names)}</tr></thead>
<tbody>
{table_rows}
</tbody>
</table>
</div>

<script>
// Chart 1: P50 Service Time per Query — grouped bar, winner marked with trophy
Plotly.newPlot('chart1', [
{chart1_js_traces}], {{
  title: 'P50 Service Time per Query (ms) — Lower is Better<br><sub>🏆 = fastest engine for that query. Missing bar = query errored on that engine.</sub>',
  barmode: 'group',
  xaxis: {{tickangle: -45, tickfont: {{size: 10}}}},
  yaxis: {{title: 'Service Time (ms)'}},
  annotations: {js_array(winner_annotations)},
  height: 600,
  margin: {{b: 180, t: 80}},
  legend: {{orientation: 'h', y: 1.12}}
}});

// Chart 2: Mean Throughput per Query — grouped bar
Plotly.newPlot('chart2', [
{chart2_js_traces}], {{
  title: 'Mean Throughput per Query (ops/s) — Higher is Better<br><sub>Only queries passing on at least one engine shown.</sub>',
  barmode: 'group',
  xaxis: {{tickangle: -45, tickfont: {{size: 10}}}},
  yaxis: {{title: 'Throughput (ops/s)'}},
  height: 600,
  margin: {{b: 180, t: 80}},
  legend: {{orientation: 'h', y: 1.12}}
}});
</script>
</body>
</html>"""

    with open(output_path, 'w') as f:
        f.write(html)
    print(f"Dashboard written to: {output_path}")
    print(f"  Engines: {', '.join(engine_names)}")
    print(f"  Total queries: {total_queries}")
    for name in engine_names:
        print(f"  {name}: {pass_counts[name]} pass, {win_counts[name]} wins")


def main():
    parser = argparse.ArgumentParser(description='Generate benchmark comparison HTML')
    parser.add_argument('--parquet-csv', help='Path to Parquet benchmark CSV')
    parser.add_argument('--lucene-csv', help='Path to Lucene benchmark CSV')
    parser.add_argument('--parquet-lucene-csv', help='Path to ParquetLucene benchmark CSV')
    # Backward compat: old scripts may pass --datafusion-csv
    parser.add_argument('--datafusion-csv', help=argparse.SUPPRESS)
    parser.add_argument('--output', default='benchmark-comparison.html', help='Output HTML path')
    parser.add_argument('--run-id', default='unknown', help='Run ID for the title')
    args = parser.parse_args()

    # Handle backward compat: --datafusion-csv maps to --parquet-csv
    if args.datafusion_csv and not args.parquet_csv:
        args.parquet_csv = args.datafusion_csv

    # Build engines dict — only include engines with a valid CSV
    engines = {}
    colors = {
        'Parquet': '#FF6B35',
        'Lucene': '#004E89',
        'ParquetLucene': '#7B2D8B',
    }

    if args.parquet_csv and os.path.exists(args.parquet_csv):
        data = parse_csv(args.parquet_csv)
        engines['Parquet'] = {'data': data, 'color': colors['Parquet'], 'query_map': build_query_map(data)}
        print(f"Parquet: {len(data)} metrics loaded from {args.parquet_csv}")

    if args.lucene_csv and os.path.exists(args.lucene_csv):
        data = parse_csv(args.lucene_csv)
        engines['Lucene'] = {'data': data, 'color': colors['Lucene'], 'query_map': build_query_map(data)}
        print(f"Lucene: {len(data)} metrics loaded from {args.lucene_csv}")

    if args.parquet_lucene_csv and os.path.exists(args.parquet_lucene_csv):
        data = parse_csv(args.parquet_lucene_csv)
        engines['ParquetLucene'] = {'data': data, 'color': colors['ParquetLucene'], 'query_map': build_query_map(data)}
        print(f"ParquetLucene: {len(data)} metrics loaded from {args.parquet_lucene_csv}")

    if len(engines) < 2:
        print(f"Error: Need at least 2 engine CSVs. Found: {list(engines.keys())}")
        sys.exit(1)

    generate_html(engines, args.run_id, args.output)


if __name__ == '__main__':
    main()
