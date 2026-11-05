#!/usr/bin/env python3
"""Genera icons/icon-180.png, 192 y 512 con Pillow. Uso: python tools/generar_iconos.py"""
import os
from PIL import Image, ImageDraw
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'icons')
S = 1024
im = Image.new('RGB', (S, S), '#1F4E79')
top, bot = (44, 108, 166), (22, 58, 92)
for y in range(S):
    t = y / S
    ImageDraw.Draw(im).line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
d = ImageDraw.Draw(im)
k = S / 64
shield = [(32, 10), (13, 17), (13, 31), (15, 40), (21, 48), (32, 55), (43, 48), (49, 40), (51, 31), (51, 17)]
d.polygon([(x * k, y * k) for x, y in shield], fill='white')
d.line([(x * k, y * k) for x, y in [(21, 41), (21, 23), (32, 34), (43, 23), (43, 41)]], fill='#1F4E79', width=int(5.4 * k), joint='curve')
for x, y in [(21, 41), (21, 23), (32, 34), (43, 23), (43, 41)]:
    r = 2.7 * k; d.ellipse([x * k - r, y * k - r, x * k + r, y * k + r], fill='#1F4E79')
r = 5.5 * k; d.ellipse([46 * k - r, 15 * k - r, 46 * k + r, 15 * k + r], fill='#1BAF7A')
for n in (180, 192, 512):
    im.resize((n, n), Image.LANCZOS).save(f'{OUT}/icon-{n}.png', optimize=True)
print('ok')
