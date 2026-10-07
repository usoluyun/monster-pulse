#!/usr/bin/env python3
"""独立于快照的 Dock 语义检查：竖柱分区、向上填充、开关独立、静态相位。"""
import runpy
import sys
from pathlib import Path

read_png = runpy.run_path(str(Path(__file__).with_name('pixel-diff.py')))['read_png']
root = Path(sys.argv[1])
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


def load(name):
    return read_png(root / (name + '.png'))


def colored(name, kind):
    w, h, c, data = load(name)
    points = []
    for y in range(h):
        for x in range(w):
            r, g, b = data[(y*w+x)*c:(y*w+x)*c+3]
            hit = g > r+40 and (b > r+40 if kind == 'cpu' else g > b+40)
            if hit:
                points.append((x*128/w, 128-y*128/h))
    return points


for name, kind, left in [('cpu-full', 'cpu', 80), ('gpu-full', 'gpu', 104)]:
    points = colored(name, kind)
    check(bool(points), f'{kind} 满载必须有彩色柱')
    if points:
        check(all(left-1 <= x <= left+15 and 37 <= y <= 99 for x,y in points),
              f'{kind} 必须留在右侧独立槽位，不能盖住数字或额度轨')
        check(max(y for x,y in points)-min(y for x,y in points) > 55,
              f'{kind} 满载必须沿竖向填满')
check(not colored('zero-load', 'cpu') and not colored('zero-load', 'gpu'),
      '零负载不可画成非零填充')
points = colored('low-cpu-45', 'cpu')
check(bool(points) and max(y for x,y in points) < 44,
      '低 CPU 负载必须从底部向上填充')
check(bool(colored('hide-gpu', 'cpu')) and not colored('hide-gpu', 'gpu'),
      '隐藏 GPU 不应隐藏 CPU')
check(bool(colored('hide-cpu', 'gpu')) and not colored('hide-cpu', 'cpu'),
      '隐藏 CPU 不应隐藏 GPU')
check(load('blink-on') == load('blink-off'), '静态图标不能随历史动画相位改变')
check(load('no-quota') == load('no-quota-stale'), '无额度快照时不可标成旧数据')
check(load('gpu-unavailable') != load('zero-load'), '无 GPU 数据必须与零负载区分')
def ring_white(name):
    w,h,c,data = load(name)
    count = 0
    for y in range(h):
        for x in range(w):
            radius = ((x*128/w-41.5)**2+(128-y*128/h-68.5)**2)**0.5
            if 26.5 <= radius <= 30.5:
                rgb = data[(y*w+x)*c:(y*w+x)*c+3]
                if min(rgb) > 190:
                    count += 1
    return count

check(ring_white('quota-full') > 100 and ring_white('quota-empty') == 0,
      '剩余圆环必须满额全亮、耗尽为空，方向不能反成已用')
def proxy_pixels(name):
    w,h,c,data = load(name)
    return bytes(channel for y in range(h) for x in range(w)
                 if 54 <= x*128/w <= 65 and 103 <= 128-y*128/h <= 114
                 for channel in data[(y*w+x)*c:(y*w+x)*c+c])

check(proxy_pixels('network-off') != proxy_pixels('network-unknown'),
      '代理关闭与读取失败不可使用同一状态')
check(proxy_pixels('network-off') != proxy_pixels('normal-92'),
      '代理开启与关闭必须有不同标记')
for message in failures:
    print('  FAIL Dock 语义：' + message)
if failures:
    sys.exit(1)
print('  PASS Dock 语义：分区、竖向填充、独立开关、静态相位、缺失数据')
