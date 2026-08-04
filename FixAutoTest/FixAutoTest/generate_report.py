#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FIX AutoTest HTML 报告生成器
用法: python3 generate_report.py [test_report.json] [output.html]
默认: 读取 test_report.json → 输出 test_report.html
"""

import json
import os
import sys
from datetime import datetime

def generate_report(json_path='test_report.json', output_path='test_report.html'):
    if not os.path.exists(json_path):
        print(f"错误: 找不到 {json_path}")
        sys.exit(1)

    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    summary = data.get('summary', {})
    total = summary.get('total_cases', 0)
    pass_count = summary.get('pass', 0)
    fail_count = summary.get('fail', 0)
    skip_count = summary.get('skip', 0)
    nocompare_count = summary.get('nocompare', 0)
    timestamp = data.get('timestamp', datetime.now().isoformat())

    # ---- 饼图 SVG ----
    def pie_svg(p, f, s):
        """生成内嵌 SVG 饼图"""
        total = p + f + s
        if total == 0:
            return '<p>无测试数据</p>'
        colors = {'pass': '#27ae60', 'fail': '#e74c3c', 'skip': '#95a5a6'}
        slices = []
        offset = 0
        items = [('pass', p, colors['pass']), ('fail', f, colors['fail']), ('skip', s, colors['skip'])]
        for _, count, color in items:
            if count == 0:
                continue
            pct = count / total
            angle = pct * 360
            if pct >= 1:
                slices.append(f'<circle r="60" cx="100" cy="100" fill="{color}"/>')
            else:
                start_x = 100 + 60 * __cos(offset - 90)
                start_y = 100 + 60 * __sin(offset - 90)
                end_x = 100 + 60 * __cos(offset + angle - 90)
                end_y = 100 + 60 * __sin(offset + angle - 90)
                large = 1 if angle > 180 else 0
                slices.append(
                    f'<path d="M100,100 L{start_x},{start_y} A60,60 0 {large},1 {end_x},{end_y} Z" fill="{color}"/>'
                )
            offset += angle
        svg = '<svg viewBox="0 0 200 200" width="180" height="180">' + ''.join(slices) + '</svg>'
        return svg

    def __cos(deg):
        import math
        return round(math.cos(math.radians(deg)), 10)

    def __sin(deg):
        import math
        return round(math.sin(math.radians(deg)), 10)

    # ---- 用例详情行 ----
    def case_rows(cases):
        rows = []
        for case in cases:
            fname = case.get('file', 'unknown')
            c_total = case.get('total', 0)
            c_pass = case.get('pass', 0)
            c_fail = case.get('fail', 0)
            c_skip = case.get('skip', 0)
            c_no = case.get('nocompare', 0)
            details = case.get('details', [])
            status_icon = '✅' if c_fail == 0 else '❌'
            fail_class = '' if c_fail == 0 else ' case-fail'
            rows.append(f'''
            <tr class="case-row{fail_class}" onclick="toggleDetail(this)">
                <td>{status_icon}</td>
                <td>{fname}</td>
                <td>{c_total}</td>
                <td class="pass">{c_pass}</td>
                <td class="fail">{c_fail}</td>
                <td class="skip">{c_skip + c_no}</td>
            </tr>
            <tr class="detail-row" style="display:none">
                <td colspan="6">
                    <table class="step-table">
                        <tr><th>Step</th><th>Result</th></tr>
                        {''.join(step_row(d) for d in details)}
                    </table>
                </td>
            </tr>''')
        return ''.join(rows)

    def step_row(detail):
        result = detail.get('result', '')
        if result == 'PASS':
            icon = '✅'
            cls = 'step-pass'
        elif result == 'FAIL':
            icon = '❌'
            cls = 'step-fail'
        else:
            icon = '⏭'
            cls = 'step-skip'
        return f'<tr class="{cls}"><td>{icon} Step {detail.get("step","?")}</td><td>{result}</td></tr>'

    # ---- 失败详情 ----
    def failure_rows(failures):
        if not failures:
            return '<p style="color:#27ae60;text-align:center">🎉 所有用例通过！</p>'
        rows = []
        for f in failures:
            rows.append(f'''
            <tr>
                <td>{f.get('case','')}</td>
                <td>{f.get('step','')}</td>
                <td>{f.get('tag','')}</td>
                <td class="exp">{f.get('expected','')}</td>
                <td class="act">{f.get('actual','')}</td>
            </tr>''')
        return f'''
        <table class="fail-table">
            <tr><th>用例</th><th>步骤</th><th>Tag</th><th>期望值</th><th>实际值</th></tr>
            {''.join(rows)}
        </table>'''

    failures = data.get('failures', [])
    cases = data.get('cases', [])

    # ---- HTML 模板 ----
    html = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FIX AutoTest Report</title>
<style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f6fa; color: #2c3e50; padding: 20px; }}
.header {{ background: linear-gradient(135deg, #2c3e50, #3498db); color: #fff; padding: 30px 40px; border-radius: 12px; margin-bottom: 24px; }}
.header h1 {{ font-size: 24px; margin-bottom: 6px; }}
.header .time {{ font-size: 13px; opacity: .8; }}
.cards {{ display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }}
.card {{ flex: 1; min-width: 120px; background: #fff; border-radius: 10px; padding: 20px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,.06); }}
.card .num {{ font-size: 32px; font-weight: 700; }}
.card .label {{ font-size: 13px; color: #7f8c8d; margin-top: 4px; }}
.card.total .num {{ color: #2c3e50; }}
.card.pass .num {{ color: #27ae60; }}
.card.fail .num {{ color: #e74c3c; }}
.card.skip .num {{ color: #95a5a6; }}
.section {{ background: #fff; border-radius: 10px; padding: 24px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,.06); }}
.section h2 {{ font-size: 18px; margin-bottom: 16px; border-bottom: 2px solid #ecf0f1; padding-bottom: 10px; }}
.chart-wrap {{ display: flex; align-items: center; gap: 30px; flex-wrap: wrap; }}
.legend {{ display: flex; flex-direction: column; gap: 8px; }}
.legend-item {{ display: flex; align-items: center; gap: 8px; font-size: 14px; }}
.legend-dot {{ width: 12px; height: 12px; border-radius: 50%; }}
table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
th {{ text-align: left; padding: 10px 12px; background: #f8f9fa; border-bottom: 2px solid #dee2e6; color: #495057; }}
td {{ padding: 10px 12px; border-bottom: 1px solid #eee; }}
.case-row {{ cursor: pointer; transition: background .2s; }}
.case-row:hover {{ background: #f0f4ff; }}
.case-fail {{ border-left: 4px solid #e74c3c; }}
.detail-row td {{ padding: 0; }}
.step-table {{ margin: 10px 20px; width: auto; font-size: 13px; }}
.step-pass {{ color: #27ae60; }}
.step-fail {{ color: #e74c3c; font-weight: 600; }}
.step-skip {{ color: #95a5a6; }}
.fail-table .exp {{ color: #27ae60; font-family: monospace; }}
.fail-table .act {{ color: #e74c3c; font-family: monospace; }}
.pass {{ color: #27ae60; font-weight: 600; }}
.fail {{ color: #e74c3c; font-weight: 600; }}
.skip {{ color: #95a5a6; }}
.footer {{ text-align: center; color: #95a5a6; font-size: 12px; margin-top: 30px; }}
@media (max-width: 768px) {{ .cards {{ flex-direction: column; }} .card {{ min-width: auto; }} }}
</style>
<script>
function toggleDetail(row) {{
    var next = row.nextElementSibling;
    if (next && next.classList.contains('detail-row')) {{
        next.style.display = next.style.display === 'none' ? 'table-row' : 'none';
    }}
}}
</script>
</head>
<body>

<div class="header">
    <h1>FIX AutoTest Report</h1>
    <div class="time">{timestamp}</div>
</div>

<div class="cards">
    <div class="card total">
        <div class="num">{total}</div>
        <div class="label">Total Cases</div>
    </div>
    <div class="card pass">
        <div class="num">{pass_count}</div>
        <div class="label">Pass</div>
    </div>
    <div class="card fail">
        <div class="num">{fail_count}</div>
        <div class="label">Fail</div>
    </div>
    <div class="card skip">
        <div class="num">{skip_count + nocompare_count}</div>
        <div class="label">Skip / NoCompare</div>
    </div>
</div>

<div class="section">
    <h2>通过率</h2>
    <div class="chart-wrap">
        {pie_svg(pass_count, fail_count, skip_count + nocompare_count)}
        <div class="legend">
            <div class="legend-item"><span class="legend-dot" style="background:#27ae60"></span> Pass: {pass_count}{f' ({pass_count*100//(pass_count+fail_count+skip_count+nocompare_count)}%)' if (pass_count+fail_count+skip_count+nocompare_count) > 0 else ''}</div>
            <div class="legend-item"><span class="legend-dot" style="background:#e74c3c"></span> Fail: {fail_count}{f' ({fail_count*100//(pass_count+fail_count+skip_count+nocompare_count)}%)' if fail_count > 0 else ''}</div>
            <div class="legend-item"><span class="legend-dot" style="background:#95a5a6"></span> Skip/NoCompare: {skip_count + nocompare_count}</div>
        </div>
    </div>
</div>

<div class="section">
    <h2>失败详情</h2>
    {failure_rows(failures)}
</div>

<div class="section">
    <h2>用例明细（点击展开）</h2>
    <table>
        <tr><th></th><th>用例文件</th><th>总计</th><th>PASS</th><th>FAIL</th><th>SKIP</th></tr>
        {case_rows(cases)}
    </table>
</div>

<div class="footer">
    FIX AutoTest Report · Generated by generate_report.py
</div>

</body>
</html>'''

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"报告已生成: {os.path.abspath(output_path)}")


if __name__ == '__main__':
    json_path = sys.argv[1] if len(sys.argv) > 1 else 'test_report.json'
    output_path = sys.argv[2] if len(sys.argv) > 2 else 'test_report.html'
    generate_report(json_path, output_path)
