#!/usr/bin/env python3
"""窗口渲染应自带不透明深色背景，不能借用查看器的底色才能读到文字。"""
import runpy
import sys
from pathlib import Path

read_png = runpy.run_path(str(Path(__file__).with_name("pixel-diff.py")))["read_png"]
work = Path(sys.argv[1])
failures = []
paths = [path for path in sorted(work.glob("*.png"))
         if path.name.startswith(("details-", "settings-"))]
if not paths:
    failures.append("未找到详情或设置窗口图片")
for path in paths:
    _, _, channels, pixels = read_png(path)
    if channels not in (3, 4):
        failures.append(f"{path.name}: 不支持的色彩通道 {channels}")
        continue
    if channels == 4 and any(alpha != 255 for alpha in pixels[3::4]):
        failures.append(f"{path.name}: 窗口背景或内容存在透明像素")
    corner = pixels[:3]
    if not (0 < max(corner) < 100 and max(corner) - min(corner) < 5):
        failures.append(f"{path.name}: 左上角不是已固定的深灰窗口背景")
if failures:
    print("  FAIL 窗口渲染背景：" + "; ".join(failures))
    sys.exit(1)
print("  PASS 窗口渲染背景：不透明、固定深色外观")
