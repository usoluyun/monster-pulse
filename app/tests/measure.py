#!/usr/bin/env python3
"""测量单个进程的累计资源占用，含其子进程。

按 docs/codex-dock-feasibility.md §性能验收方法 的口径采集：
累计 CPU 时间、平均 CPU、物理内存 footprint、峰值内存。

关键口径说明（文档明确要求，容易做错）：
  · 用 footprint 不用 RSS —— RSS 含共享页，父子进程相加会重复计入；
    这里对「应用 + 各自子进程」分别取 footprint 后求和作为物理内存口径。
  · 累计 CPU 时间取 utime+stime，包含被回收的子进程 —— 额度查询的辅助
    codex 进程每次只活几秒，结束时 ps 就看不到它了，只看活着的进程会漏算。
  · 「唤醒次数」需要 powermetrics（sudo），本脚本不采集，单独标注。

用法：
  measure.py <label> <duration_s> <interval_s> -- <cmd> [args...]
输出 CSV 到 stdout。
"""

import csv
import os
import subprocess
import sys
import time


def snapshot_root(pid):
    """返回 (累计CPU秒, 物理内存KB, 子进程CPU秒, 子进程内存KB, 子进程数)。"""
    try:
        out = subprocess.run(
            ["ps", "-o", "cputime=,rss=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5).stdout.split()
    except Exception:
        return 0.0, 0, 0.0, 0, 0
    if not out:
        return 0.0, 0, 0.0, 0, 0
    cpu = parse_cputime(out[0])
    return cpu, 0, 0.0, 0, 0


def parse_cputime(s):
    """把 ps 的 [[dd-]hh:]mm:ss 转成秒。"""
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [float(p) for p in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, sec = parts
    return days * 86400 + h * 3600 + m * 60 + sec


def descendants(root):
    """收集 root 的全部后代 pid。用 ps 全表 + 父子映射，不依赖 psutil。"""
    out = subprocess.run(["ps", "-Ao", "pid=,ppid="],
                         capture_output=True, text=True).stdout
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    result, stack = [], [root]
    while stack:
        for kid in children.get(stack.pop(), []):
            result.append(kid)
            stack.append(kid)
    return result


def footprint_kb(pid):
    """footprint 输出的 Footprint 行，带单位，换算成 KB。"""
    try:
        out = subprocess.run(["footprint", "-p", str(pid)],
                             capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return 0
    for line in out.splitlines():
        if "Footprint:" in line:
            parts = line.split("Footprint:")[1].split()
            if len(parts) < 2:
                return 0
            try:
                val, unit = float(parts[0]), parts[1]
            except ValueError:
                return 0
            return int(val * 1024 * 1024 if unit == "GB"
                       else val * 1024 if unit == "MB"
                       else val if unit == "KB" else val / 1024)
    return 0


def cputime_of(pid):
    try:
        out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return parse_cputime(out) if out else 0.0
    except Exception:
        return 0.0


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def usage():
    print(
        "用法: measure.py --pid <pid> <label> <duration_s> <interval_s>\n"
        "\n"
        "只测量**已在运行**的进程，不负责启动与结束——状态由调用方摆好。\n"
        "这点很关键：App 场景要先摆好状态（详情窗开/关）再开始计量；\n"
        "而用 `open -a` 启动活动监视器会立即退出，拿它当被测命令会测到空。"
    )


def main():
    args = sys.argv[1:]
    if "--pid" not in args or len(args) < 5:
        usage()
        return 1

    i = args.index("--pid")
    pid = int(args[i + 1])
    label, duration, interval = args[i + 2], float(args[i + 3]), float(args[i + 4])

    if not pid_alive(pid):
        sys.exit("pid %s 不存在，先启动目标再测量" % pid)

    time.sleep(2)   # 稳定期：让启动开销与首次查询落在计量区间之外

    writer = csv.writer(sys.stdout)
    writer.writerow(["label", "elapsed_s", "root_cpu_s", "child_cpu_s",
                     "total_phys_kb", "peak_phys_kb", "n_children"])

    t0 = time.time()
    peak = 0
    n = 0
    while True:
        elapsed = time.time() - t0
        if elapsed >= duration:
            break
        kids = descendants(pid)
        root_cpu = cputime_of(pid)
        child_cpu = sum(cputime_of(k) for k in kids)
        # 物理内存：各进程 footprint 求和（不用 RSS，避免共享页重复计入）
        phys = footprint_kb(pid) + sum(footprint_kb(k) for k in kids)
        peak = max(peak, phys)
        writer.writerow([label, f"{elapsed:.1f}", f"{root_cpu:.2f}",
                         f"{child_cpu:.2f}", phys, peak, len(kids)])
        sys.stdout.flush()
        n += 1
        time.sleep(interval)

    # 不终止被测进程：它的状态与存活由调用方决定，这里只负责计量
    total_cpu = cputime_of(pid) + sum(cputime_of(k) for k in descendants(pid))
    print(f"# {label}: 采样 {n} 点 / {duration:.0f}s  "
          f"末次累计CPU={total_cpu:.1f}s  峰值物理内存={peak/1024:.1f}MB  "
          f"平均CPU={(total_cpu/duration*100):.2f}%", file=sys.stderr)


if __name__ == "__main__":
    main()