#!/usr/bin/env python3
"""Genera íconos y logos desde tools/logo-original.png. Uso: python tools/generar_iconos.py"""
import os
from PIL import Image
RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(RAIZ, 'icons')
orig = Image.open(os.path.join(RAIZ, 'tools', 'logo-original.png')).convert('RGBA')
W, H = orig.size
# El escudo ocupa la parte superior; el texto MY CLUB parte bajo la fila vacía que los separa
alpha = orig.getchannel('A').point(lambda v: 255 if v > 40 else 0)
filas = [alpha.crop((0, y, W, y + 1)).getbbox() is not None for y in range(H)]
inicio = next(y for y in range(H) if filas[y])
corte = next((y for y in range(inicio + H // 2, H) if not filas[y]), int(H * 0.81))
caja = alpha.crop((0, 0, W, corte)).getbbox()
escudo = orig.crop(caja)
print('escudo', caja, 'corte', corte)
def encajar(img, lado):
    t = img.copy(); t.thumbnail((lado, lado), Image.LANCZOS)
    lienzo = Image.new('RGBA', (lado, lado), (0, 0, 0, 0))
    lienzo.paste(t, ((lado - t.width) // 2, (lado - t.height) // 2), t)
    return lienzo
encajar(escudo, 192).save(f'{OUT}/escudo.png', optimize=True)
c = orig.crop(alpha.getbbox()); c.thumbnail((640, 700), Image.LANCZOS); c.save(f'{OUT}/logo.png', optimize=True)
# Ícono opaco (iOS no admite transparencia), con el escudo dentro de la zona segura
base = Image.new('RGB', (1024, 1024))
sup, inf = (31, 78, 121), (14, 42, 68)
for y in range(1024):
    t = y / 1023; base.paste(tuple(int(sup[i] + (inf[i] - sup[i]) * t) for i in range(3)), (0, y, 1024, y + 1))
e = encajar(escudo, 790); base.paste(e, (117, 117), e)
for n in (180, 192, 512):
    base.resize((n, n), Image.LANCZOS).save(f'{OUT}/icon-{n}.png', optimize=True)
print('ok')
