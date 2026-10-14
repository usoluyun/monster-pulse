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
        check(all(left-1 <= x <= left+15 and 71 <= y <= 99 for x,y in points),
              f'{kind} 必须留在右侧独立槽位，不能盖住数字或额度轨')
        check(max(y for x,y in points)-min(y for x,y in points) > 23,
              f'{kind} 满载必须沿竖向填满')
check(not colored('zero-load', 'cpu') and not colored('zero-load', 'gpu'),
      '零负载不可画成非零填充')
points = colored('low-cpu-45', 'cpu')
check(bool(points) and max(y for x,y in points) < 76,
      '低 CPU 负载必须从底部向上填充')
check(bool(colored('hide-gpu', 'cpu')) and not colored('hide-gpu', 'gpu'),
      '隐藏 GPU 不应隐藏 CPU')
check(bool(colored('hide-cpu', 'gpu')) and not colored('hide-cpu', 'cpu'),
      '隐藏 CPU 不应隐藏 GPU')
# 全部关闭时，计量区连底槽一起消失；三项时缺项由同列剩余项填满。
w,h,c,data = load('hide-all')
samples = [data[(y*w+x)*c:(y*w+x)*c+3]
           for y in range(h) for x in range(w)
           if 82 <= x*128/w <= 115 and 40 <= 128-y*128/h <= 96]
check(bool(samples) and all(max(rgb) < 35 for rgb in samples), '全部关闭后计量区应消失')
for name, kind in [('hide-memory','cpu'), ('hide-disk','gpu')]:
    points = colored(name,kind)
    check(bool(points) and min(y for x,y in points) < 41,
          f'{name} 同列剩余柱必须从完整区域底部开始填充')
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

def annulus_lit(name):
    """外圈下弧的非背景像素数（轨道暗灰、弧线亮，都算）。

    只取 y>=84 那一段：金额大字占 y 54–78，整环去量会把文字当成圆环——
    第一次写这条断言就是这么错的，实测 wallet-1721 数出几百个「环上像素」。
    实测分离度很干净：Codex 各例 925，New API 各例 0。
    """
    w,h,c,data = load(name)
    count = 0
    for y in range(h):
        for x in range(w):
            py = 128-y*128/h
            if py < 84:
                continue
            radius = ((x*128/w-41.5)**2+(py-68.5)**2)**0.5
            if 26.5 <= radius <= 30.5 and max(data[(y*w+x)*c:(y*w+x)*c+3]) > 35:
                count += 1
    return count

# 正反两条一起锁：画不画外圈由**来源**决定，不由「有没有百分比」决定。
# 只锁 New API 会漏掉反向错误——曾用 remaining != nil 推断来源，于是 Codex
# 还没查到数据时（remaining 同样是 nil）空圈整个消失，图标形状随查询状态跳变。
for name in ['wallet-1721', 'wallet-short', 'wallet-5digits',
             'wallet-share-high', 'wallet-share-low']:
    check(annulus_lit(name) == 0,
          f'{name} 不得画额度外圈：New API 没有周期分母，空圈会被读成「进度还没开始」')
check(annulus_lit('no-quota') > 100, 'Codex 尚无数据时外圈必须保留，否则图标形状随查询状态跳变')
check(annulus_lit('normal-92') > 100, 'Codex 有数据时外圈必须保留')

def wallet_remain_bar_width(name):
    """累计比例条「还剩」段（黄/橙）的水平跨度。条在 scene y≈46–51、x≈12–72。"""
    w, h, c, data = load(name)
    xs = []
    for y in range(h):
        py = 128 - y * 128 / h
        if not (45.5 <= py <= 51.5):
            continue
        for x in range(w):
            sx = x * 128 / w
            if not (11 <= sx <= 73):
                continue
            r, g, b = data[(y * w + x) * c:(y * w + x) * c + 3]
            # 还剩段：偏黄（R、G 明显高于 B）；已花段是浅灰，不计入。
            if r > 140 and g > 110 and r - b > 40 and g - b > 20:
                xs.append(sx)
    return (max(xs) - min(xs)) if xs else 0.0

high_w = wallet_remain_bar_width('wallet-share-high')
low_w = wallet_remain_bar_width('wallet-share-low')
check(high_w > 35, f'高累计剩余必须有明显还剩段，实际跨度 {high_w:.1f}')
check(low_w > 0.5, f'低累计剩余仍应有还剩段，实际跨度 {low_w:.1f}')
check(high_w > low_w * 2,
      f'累计还剩段必须随 share 变长：high={high_w:.1f} low={low_w:.1f}')
check(wallet_remain_bar_width('wallet-1721') > 0.5,
      'wallet-1721 必须画出累计比例条')
def proxy_pixels(name):
    w,h,c,data = load(name)
    return bytes(channel for y in range(h) for x in range(w)
                 if 54 <= x*128/w <= 65 and 103 <= 128-y*128/h <= 114
                 for channel in data[(y*w+x)*c:(y*w+x)*c+c])

check(proxy_pixels('network-off') != proxy_pixels('network-unknown'),
      '代理关闭与读取失败不可使用同一状态')
check(proxy_pixels('network-off') != proxy_pixels('normal-92'),
      '代理开启与关闭必须有不同标记')
# 各槽位独立检查满载、读写差异与缺失值，避免只验证旧 CPU/GPU。
def region(name, left, bottom, width=13.5):
    w,h,c,data = load(name)
    return bytes(channel for y in range(h) for x in range(w)
                 if left+1 <= x*128/w <= left+width-1 and bottom+2 <= 128-y*128/h <= bottom+24
                 for channel in data[(y*w+x)*c:(y*w+x)*c+c])
check(region('memory-full',80,38) != region('zero-load',80,38), '内存满载必须显示')
check(region('disk-read-full',104,38,6) != region('zero-load',104,38,6), '磁盘读必须显示在左半格')
check(region('disk-read-full',111.5,38,6) == region('zero-load',111.5,38,6), '只读时写柱必须为零')
check(region('disk-write-full',111.5,38,6) != region('zero-load',111.5,38,6), '磁盘写必须显示在右半格')
check(region('disk-write-full',104,38,6) == region('zero-load',104,38,6), '只写时读柱必须为零')
check(region('memory-unavailable',80,38) != region('zero-load',80,38), '无内存读数应区别于零')
check(region('disk-unavailable',104,38) != region('zero-load',104,38), '无磁盘读数应区别于零')
# 每种开关组合都必须填满可用的竖向空间，不残留关闭项的底槽。
for mask in range(16):
    active = [slot for slot in range(4) if mask & (1 << slot)]
    w,h,c,data = load(f'reflow-{mask}')
    def rgb_at(x,y):
        px,py = int(x*w/128),int((128-y)*h/128)
        return data[(py*w+px)*c:(py*w+px)*c+3]
    def lit(x,y):
        rgb = rgb_at(x,y)
        return max(rgb)-min(rgb) > 40
    if not active:
        check(all(max(rgb_at(x,y)) < 35 for x in [84,108] for y in [42,68,94]),
              '零项不能残留底槽')
        continue
    if len(active) <= 2:
        centers = [94] if len(active) == 1 else [86,108]
        check(all(lit(x,y) for x in centers for y in [42,68,94]),
              f'组合 {mask} 的长柱必须填满完整高度')
        if len(active) == 1:
            check(lit(83,68) and lit(114,68), f'组合 {mask} 单项必须占满计量区宽度')
    else:
        for col,x in [(0,86),(1,108)]:
            count = sum(slot % 2 == col for slot in active)
            check(lit(x,42) and lit(x,94), f'组合 {mask} 每列必须覆盖顶端与底端')
            check(lit(x,68) == (count == 1), f'组合 {mask} 只有独占一列时才拉长填满中间')
for message in failures:
    print('  FAIL Dock 语义：' + message)
if failures:
    sys.exit(1)
print('  PASS Dock 语义：分区、竖向填充、独立开关、静态相位、缺失数据')
