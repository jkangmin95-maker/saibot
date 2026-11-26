#!/usr/bin/env python3
"""Build public/og.png (1200x630) from public/icon-512.png. App name only, no new tagline."""
from PIL import Image, ImageDraw, ImageFont
import os

ROOT = os.path.join(os.path.dirname(__file__), '..')
W, H = 1200, 630
BG = (255, 249, 245)
CORAL = (255, 138, 128)
CORAL_SOFT = (255, 240, 238)
INK = (45, 52, 54)

img = Image.new('RGB', (W, H), BG)
draw = ImageDraw.Draw(img)
margin = 36
draw.rounded_rectangle([margin, margin, W - margin, H - margin], radius=48, fill=CORAL_SOFT, outline=CORAL, width=3)

icon = Image.open(os.path.join(ROOT, 'public/icon-512.png')).convert('RGBA')
icon_size = 260
icon = icon.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
mask = Image.new('L', (icon_size, icon_size), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, icon_size - 1, icon_size - 1], radius=56, fill=255)
icon_bg = Image.new('RGBA', (icon_size, icon_size), (255, 249, 245, 255))
icon_bg.paste(icon, (0, 0), icon)
rounded = Image.new('RGBA', (icon_size, icon_size), (0, 0, 0, 0))
rounded.paste(icon_bg, (0, 0), mask)
icon_box = Image.new('RGBA', (icon_size + 8, icon_size + 8), (0, 0, 0, 0))
ImageDraw.Draw(icon_box).rounded_rectangle([0, 0, icon_size + 7, icon_size + 7], radius=60, outline=CORAL + (255,), width=4)
icon_box.paste(rounded, (4, 4), rounded)

font = ImageFont.truetype('/usr/share/fonts/truetype/sand-box/google/Gothic A1/GothicA1-Black.ttf', 92)
text = '우리사이'
tb = draw.textbbox((0, 0), text, font=font)
tw, th = tb[2] - tb[0], tb[3] - tb[1]
gap = 36
iw, ih = icon_box.size
top = (H - (ih + gap + th)) // 2
img.paste(icon_box, ((W - iw) // 2, top), icon_box)
overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
od = ImageDraw.Draw(overlay)
tx = (W - tw) // 2
ty = top + ih + gap - tb[1]
od.text((tx, ty), text, font=font, fill=INK + (255,))
underline_y = ty + th + 16
underline_w = min(tw, 280)
od.rounded_rectangle([W // 2 - underline_w // 2, underline_y, W // 2 + underline_w // 2, underline_y + 6], radius=3, fill=CORAL + (255,))
img = Image.alpha_composite(img.convert('RGBA'), overlay).convert('RGB')
out = os.path.join(ROOT, 'public/og.png')
img.save(out, 'PNG', optimize=True)
print('wrote', out, img.size)
