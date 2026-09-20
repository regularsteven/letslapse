import json, sys, math
from PIL import Image, ImageDraw, ImageFont
src, out, mode, title = sys.argv[1:5]
d = json.load(open(src)); A = d['A']
rows = d['rows'] + d['rejected']
cols = 12; gap = 8; label_h = 20
tile_w = 150 if mode == 'rendered' else 132
tile_h = round(tile_w / A) if mode == 'rendered' else 176
n = len(rows); nrows = math.ceil(n / cols)
W = cols * (tile_w + gap) + gap; H = 36 + nrows * (tile_h + label_h + gap) + gap
im = Image.new('RGB', (W, H), (28, 28, 30)); dr = ImageDraw.Draw(im)
font = ImageFont.load_default(size=13); small = ImageFont.load_default(size=11)
dr.text((gap, 10), title, fill=(255, 255, 255), font=font)
COL = {'green': (52, 199, 89), 'amber': (255, 179, 64), 'red': (255, 59, 48)}
L = Image.Resampling.LANCZOS
for k, r in enumerate(rows):
    cx = gap + (k % cols) * (tile_w + gap); cy = 36 + (k // cols) * (tile_h + label_h + gap)
    ph = Image.open(r['file']).convert('RGB'); pw, phh = ph.size
    win = r['win']; bb = r['bbox']
    fx0, fy0 = bb['x'] / r['width'], bb['y'] / r['height']; fx1, fy1 = (bb['x'] + bb['w']) / r['width'], (bb['y'] + bb['h']) / r['height']
    if mode == 'rendered':
        box = tuple(round(v) for v in (win['left'] * pw, win['top'] * phh, (win['left'] + win['w']) * pw, (win['top'] + win['h']) * phh))
        tile = ph.crop(box).resize((tile_w, tile_h), L)
        td = ImageDraw.Draw(tile)
        td.rectangle([(fx0 - win['left']) / win['w'] * tile_w, (fy0 - win['top']) / win['h'] * tile_h, (fx1 - win['left']) / win['w'] * tile_w, (fy1 - win['top']) / win['h'] * tile_h], outline=(255, 179, 64), width=1)
        if r['rejected']:
            td.line([0, 0, tile_w, tile_h], fill=(255, 59, 48), width=3); td.line([tile_w, 0, 0, tile_h], fill=(255, 59, 48), width=3)
        im.paste(tile, (cx, cy))
    else:
        sc = min(tile_w / pw, tile_h / phh); tw, th = round(pw * sc), round(phh * sc)
        tile = ph.resize((tw, th), L).convert('RGBA')
        ov = Image.new('RGBA', (tw, th), (0, 0, 0, 130)); od = ImageDraw.Draw(ov)
        od.rectangle([win['left'] * tw, win['top'] * th, (win['left'] + win['w']) * tw, (win['top'] + win['h']) * th], fill=(0, 0, 0, 0))
        tile = Image.alpha_composite(tile, ov).convert('RGB'); td = ImageDraw.Draw(tile)
        td.rectangle([win['left'] * tw, win['top'] * th, (win['left'] + win['w']) * tw, (win['top'] + win['h']) * th], outline=(255, 255, 255), width=1)
        td.rectangle([fx0 * tw, fy0 * th, fx1 * tw, fy1 * th], outline=(255, 179, 64), width=1)
        if r['rejected']:
            td.line([0, 0, tw, th], fill=(255, 59, 48), width=3); td.line([tw, 0, 0, th], fill=(255, 59, 48), width=3)
        im.paste(tile, (cx + (tile_w - tw) // 2, cy + (tile_h - th) // 2))
    c = (160, 160, 165) if r['rejected'] else COL[r['v']]
    dr.ellipse([cx, cy + tile_h + 5, cx + 10, cy + tile_h + 15], fill=c)
    lab = ('rejected ' if r['rejected'] else f'{k + 1} · ') + f"crop {round(r['f'] * 100)} % · L {round(r['L'] * 100)} %"
    dr.text((cx + 14, cy + tile_h + 3), lab, fill=(230, 230, 232), font=small)
im.save(out); print('wrote', out, im.size)
