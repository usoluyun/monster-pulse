#!/usr/bin/env python3
"""逐像素比较两张 PNG。macOS 没 PIL，且 PNG 字节级比对会被元数据干扰，
必须解出像素再比。

⚠️ 重要限制（实测得出，勿当作精确回归）：
CoreText 文字抗锯齿的结果依赖编译产物。同一二进制连续两次渲染逐像素完全一致，
但源码任意改动后重新编译（哪怕只是加一个无关的 CLI 分支），文字像素最大可差约
22/255。因此：
  · 基准图必须由**当前构建**生成，不要跨构建复用历史基准；
  · 容差需放宽到 ~24，吸收编译抖动；
  · 这样本工具能捕获的是布局/结构错误（元素缺失、位置错乱、颜色错误），
    而不是逐像素一致。
想验证「某次视觉改动没有改变外观」，正确做法是让改动前后都用同一种方式构建，
再互相比对。

用法：pixel-diff.py a.png b.png [容差]
容差是每个通道允许的绝对差（0 = 必须完全一致），默认 0。
"""

import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG: %s" % path)

    pos, idat, ihdr = 8, bytearray(), None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
        pos += 12 + length

    if ihdr is None:
        raise ValueError("缺少 IHDR: %s" % path)
    width, height, depth, color, comp, filt, interlace = ihdr
    if depth != 8 or interlace != 0:
        raise ValueError("仅支持 8bit 非隔行，实际 depth=%d interlace=%d" % (depth, interlace))
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(height):
        ft = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if ft == 1:                      # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ft == 2:                    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:                    # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:                    # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out += line
        prev = line
    return width, height, channels, bytes(out)


def compare(pa, pb, tol=0):
    wa, ha, ca, da = read_png(pa)
    wb, hb, cb, db = read_png(pb)
    if (wa, ha) != (wb, hb):
        return {"error": "尺寸不同 %dx%d vs %dx%d" % (wa, ha, wb, hb)}
    total = wa * ha
    diff_px, max_delta, worst = 0, 0, None
    for idx in range(total):
        o = idx * ca
        q = idx * cb
        deltas = [abs(da[o + k] - db[q + k]) for k in range(min(ca, cb))]
        d = max(deltas)
        if d:
            diff_px += 1
            if d > max_delta:
                max_delta, worst = d, (idx % wa, idx // wa, deltas)
    return {
        "size": (wa, ha),
        "total": total,
        "diff_px": diff_px,
        "pct": diff_px / total * 100,
        "max_delta": max_delta,
        "worst": worst,
    }


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    tol = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    r = compare(sys.argv[1], sys.argv[2], tol)
    if "error" in r:
        print("尺寸不一致: %s" % r["error"])
        sys.exit(2)
    print("尺寸 %dx%d 共 %d 像素" % (r["size"][0], r["size"][1], r["total"]))
    print("差异像素 %d (%.4f%%)  最大通道差 %d  最严重位置 %s"
          % (r["diff_px"], r["pct"], r["max_delta"], r["worst"]))
    if r["max_delta"] <= tol:
        print("结论: 在容差 %d 内一致 ✓" % tol)
        sys.exit(0)
    print("结论: 存在可见差异 ✗")
    sys.exit(1)


if __name__ == "__main__":
    main()