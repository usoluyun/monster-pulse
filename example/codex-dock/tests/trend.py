#!/usr/bin/env python3
"""分析泄漏测试采样，判断各指标是平稳、上升还是下降。

用法：python3 trend.py /tmp/codexdock-leak.csv

判据用的是「预热后区间的线性斜率」而不是首尾差：
单次采样抖动很大（额度轮询会短暂拉起子进程），
只看首尾容易把噪声误判成泄漏或漏判真实泄漏。
"""
import csv
import sys


def slope(values):
    """最小二乘斜率（每采样点的变化量）。"""
    n = len(values)
    if n < 3:
        return 0.0
    xs = list(range(n))
    mx, my = sum(xs) / n, sum(values) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, values))
    den = sum((x - mx) ** 2 for x in xs)
    return num / den if den else 0.0


def analyze(rows, key, warmup=2):
    pts = [r for r in rows if r["elapsed_s"] >= warmup * 60 or len(rows) <= 6]
    if len(pts) < 3:
        pts = rows
    vals = [r[key] for r in pts]
    span = (pts[-1]["elapsed_s"] - pts[0]["elapsed_s"]) / 60.0 or 1
    s = slope(vals)
    per_hour = s * (len(vals) - 1) / span
    return {
        "key": key,
        "first": vals[0],
        "last": vals[-1],
        "min": min(vals),
        "max": max(vals),
        "slope": s,
        "per_hour": per_hour,
        "spread": max(vals) - min(vals),
    }


def verdict(stat):
    """按每小时变化量给结论，阈值按各指标量纲分别设定。"""
    ph = abs(stat["per_hour"])
    limits = {
        "phys_footprint_kb": 20 * 1024,   # 20 MB/h
        "rss_kb": 20 * 1024,
        "num_threads": 30,                # 线程几乎不该增长
        "num_fds": 20,                    # 句柄几乎不该增长
        "child_codex": 2,                 # 辅助进程数应恒定在 0/1
    }
    limit = limits[stat["key"]]
    if ph <= limit * 0.3:
        return "平稳"
    if ph <= limit:
        return "轻微上升（需留意）"
    return "持续上升（疑似泄漏）"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/codexdock-leak.csv"
    with open(path) as fh:
        rows = list(csv.DictReader(fh))
    if len(rows) < 3:
        print("采样点不足（%d 个），无法判断趋势" % len(rows))
        return
    for r in rows:
        try:
            r["elapsed_s"] = float(r["elapsed_s"])
        except (ValueError, TypeError):
            r["elapsed_s"] = 0.0
        # swaps 等列可能带单位（如 1168.00M），只转换能转的字段；
        # 单个脏字段留 0，不让整份分析崩掉
        for k, v in list(r.items()):
            if k == "elapsed_s":
                continue
            try:
                r[k] = int(float(v))
            except (ValueError, TypeError):
                r[k] = 0

    total_min = rows[-1]["elapsed_s"] / 60.0
    print("采样 %d 个点，覆盖 %.1f 分钟" % (len(rows), total_min))
    print()
    header = "%-20s %10s %10s %10s %12s  %s" % (
        "指标", "首次", "末次", "波动", "每小时变化", "判定")
    print(header)
    print("-" * len(header))
    worst = None
    for key in ("phys_footprint_kb", "rss_kb", "num_threads", "num_fds", "child_codex"):
        if key not in rows[0]:
            continue
        st = analyze(rows, key)
        v = verdict(st)
        print("%-20s %10d %10d %10d %12.1f  %s" % (
            key, st["first"], st["last"], st["spread"], st["per_hour"], v))
        if worst is None or abs(st["per_hour"]) > abs(worst["per_hour"]):
            worst = st
    print()
    print("主要观察对象：%s（每小时变化 %.1f）" % (worst["key"], worst["per_hour"]))
    print("提示：辅助 codex 进程数若稳定在 0/1 交替，说明每次查询都回收干净；"
          "若持续 >0 则存在泄漏。")


if __name__ == "__main__":
    main()