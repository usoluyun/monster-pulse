#!/usr/bin/env python3
"""汇总性能验收采样，得出「是否低于活动监视器」的结论。

按 docs/codex-dock-feasibility.md 的验收口径：
  · 基本条件：完整周期平均 CPU 与平均物理内存均低于活动监视器
  · 同时检查峰值与能耗是否出现不可接受的回退
  · 「可接受差值以本机基线建立，PoC 不预先编造 MB 或百分比承诺」——
    所以这里只做对比陈述，不预设阈值

用法：python3 perf-summary.py /tmp/monsterpulse-perf
"""

import csv
import glob
import os
import sys


NUMERIC = ("elapsed_s", "root_cpu_s", "child_cpu_s", "total_phys_kb",
           "peak_phys_kb", "n_children")


def load(path):
    """读采样 CSV。label 是字符串标签，别拿去做 float()。"""
    rows = []
    with open(path) as fh:
        for r in csv.DictReader(l for l in fh if not l.startswith("#")):
            try:
                rows.append({k: float(r[k]) for k in NUMERIC})
            except (ValueError, TypeError, KeyError):
                continue
    return rows


def summarize(rows):
    if not rows:
        return None
    elapsed = rows[-1]["elapsed_s"] - rows[0]["elapsed_s"]
    if elapsed <= 0:
        return None
    total_cpu = (rows[-1]["root_cpu_s"] + rows[-1]["child_cpu_s"]
                 - rows[0]["root_cpu_s"] - rows[0]["child_cpu_s"])
    peak = max(r["peak_phys_kb"] for r in rows)
    avg_phys = sum(r["total_phys_kb"] for r in rows) / len(rows)
    max_children = max(r["n_children"] for r in rows)
    return {
        "minutes": elapsed / 60.0,
        "cpu_total_s": total_cpu,
        "cpu_avg_pct": total_cpu / elapsed * 100,
        "peak_mb": peak / 1024.0,
        "avg_mb": avg_phys / 1024.0,
        "max_children": int(max_children),
    }


def collect(outdir):
    groups = {"dock": [], "am": []}
    for path in sorted(glob.glob(os.path.join(outdir, "*.csv"))):
        name = os.path.basename(path)
        key = "dock" if name.startswith("dock") else "am" if name.startswith("am") else None
        if not key:
            continue
        st = summarize(load(path))
        if st:
            st["file"] = os.path.basename(path)
            groups[key].append(st)
    return groups


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/monsterpulse-perf"
    g = collect(outdir)
    dock, am = g["dock"], g["am"]
    if not dock:
        sys.exit("没有找到 MonsterPulse 采样文件（%s/dock-*.csv）" % outdir)

    print("=" * 78)
    print("性能验收汇总：%d 轮 MonsterPulse vs %d 轮 活动监视器" % (len(dock), len(am)))
    print("=" * 78)
    for label, runs in (("MonsterPulse", dock), ("活动监视器", am)):
        if not runs:
            continue
        print("\n%s" % label)
        print("  %-26s %8s %10s %10s %10s %8s" % (
            "轮次", "时长min", "均CPU%", "累计CPU s", "均内存MB", "峰值MB"))
        for r in runs:
            print("  %-26s %8.1f %10.2f %10.1f %10.1f %8.1f" % (
                r["file"], r["minutes"], r["cpu_avg_pct"], r["cpu_total_s"],
                r["avg_mb"], r["peak_mb"]))
        print("  %-26s %8s %10.2f %10.1f %10.1f %8.1f" % (
            "平均", "-", mean([r["cpu_avg_pct"] for r in runs]),
            mean([r["cpu_total_s"] for r in runs]),
            mean([r["avg_mb"] for r in runs]),
            mean([r["peak_mb"] for r in runs])))

    if not am:
        print("\n未找到活动监视器采样，无法做对比结论。")
        return

    d_cpu, a_cpu = mean([r["cpu_avg_pct"] for r in dock]), mean([r["cpu_avg_pct"] for r in am])
    d_mem, a_mem = mean([r["avg_mb"] for r in dock]), mean([r["avg_mb"] for r in am])
    print("\n" + "-" * 78)
    print("对比（MonsterPulse 相对 活动监视器）")
    print("-" * 78)
    for name, d, a, lower_better in (("平均 CPU", d_cpu, a_cpu, True),
                                     ("平均物理内存", d_mem, a_mem, True)):
        if a == 0:
            continue
        ratio = d / a
        verdict = "低于（达标）" if (ratio < 1) == lower_better else "高于（未达标）"
        print("  %-14s MonsterPulse %8.2f  vs  活动监视器 %8.2f  →  %5.1f%%  %s" % (
            name, d, a, ratio * 100, verdict))
    print("\n未覆盖：唤醒次数与能耗（需 powermetrics + sudo）。")
    print("峰值内存对比见上表；文档要求同时检查峰值是否出现不可接受的回退。")


if __name__ == "__main__":
    main()