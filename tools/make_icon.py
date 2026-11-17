#!/usr/bin/env python3
"""Draws the app icon (iPod front: dark screen + click wheel) into Resources/AppIcon.iconset."""
import os
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas (4x of 1024)
k = S / 1024

def sq(x): return int(x * k)

def squircle_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m

def vgradient(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# drop shadow
body_box = (sq(100), sq(100), sq(924), sq(924))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((sq(100), sq(118), sq(924), sq(942)), radius=sq(185), fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(sq(18)))
img.alpha_composite(shadow)

# body: brushed white/silver
body = vgradient((S, S), (252, 252, 254), (222, 224, 230)).convert("RGBA")
img.paste(body, (0, 0), squircle_mask((S, S), body_box, sq(185)))

d = ImageDraw.Draw(img)
# subtle inner rim
d.rounded_rectangle(body_box, radius=sq(185), outline=(255, 255, 255, 200), width=sq(4))

# screen
screen_box = (sq(250), sq(190), sq(774), sq(500))
scr = vgradient((screen_box[2] - screen_box[0], screen_box[3] - screen_box[1]), (40, 70, 120), (14, 22, 40)).convert("RGBA")
mask = squircle_mask(scr.size, (0, 0, scr.size[0], scr.size[1]), sq(34))
img.paste(scr, screen_box[:2], mask)
d.rounded_rectangle(screen_box, radius=sq(34), outline=(20, 24, 32, 255), width=sq(6))

# music note on screen
cx, cy = sq(502), sq(352)
note = (255, 255, 255, 235)
d.ellipse((cx - sq(78), cy + sq(18), cx - sq(10), cy + sq(72)), fill=note)
d.ellipse((cx + sq(30), cy + sq(2), cx + sq(98), cy + sq(56)), fill=note)
d.rectangle((cx - sq(22), cy - sq(88), cx - sq(10), cy + sq(46)), fill=note)
d.rectangle((cx + sq(86), cy - sq(104), cx + sq(98), cy + sq(30)), fill=note)
d.polygon([(cx - sq(22), cy - sq(88)), (cx + sq(98), cy - sq(118)), (cx + sq(98), cy - sq(84)), (cx - sq(22), cy - sq(54))], fill=note)

# click wheel
wc = (sq(512), sq(705))
r_out, r_in = sq(170), sq(62)
wheel = Image.new("RGBA", (S, S), (0, 0, 0, 0))
wd = ImageDraw.Draw(wheel)
wd.ellipse((wc[0] - r_out, wc[1] - r_out, wc[0] + r_out, wc[1] + r_out), fill=(236, 237, 241, 255), outline=(196, 198, 206, 255), width=sq(5))
img.alpha_composite(wheel)
# accent ring
d.ellipse((wc[0] - r_out + sq(26), wc[1] - r_out + sq(26), wc[0] + r_out - sq(26), wc[1] + r_out - sq(26)), outline=(10, 132, 255, 255), width=sq(10))
# center button
d.ellipse((wc[0] - r_in, wc[1] - r_in, wc[0] + r_in, wc[1] + r_in), fill=(250, 250, 252, 255), outline=(196, 198, 206, 255), width=sq(5))
# wheel labels as small marks
mark = (120, 124, 134, 255)
d.rectangle((wc[0] - sq(22), wc[1] - sq(128), wc[0] + sq(22), wc[1] - sq(118)), fill=mark)          # menu
d.polygon([(wc[0] + sq(112), wc[1]), (wc[0] + sq(96), wc[1] - sq(12)), (wc[0] + sq(96), wc[1] + sq(12))], fill=mark)  # next
d.polygon([(wc[0] - sq(112), wc[1]), (wc[0] - sq(96), wc[1] - sq(12)), (wc[0] - sq(96), wc[1] + sq(12))], fill=mark)  # prev
d.rectangle((wc[0] - sq(16), wc[1] + sq(110), wc[0] - sq(8), wc[1] + sq(130)), fill=mark)            # play/pause
d.rectangle((wc[0] - sq(2), wc[1] + sq(110), wc[0] + sq(6), wc[1] + sq(130)), fill=mark)
d.polygon([(wc[0] + sq(10), wc[1] + sq(110)), (wc[0] + sq(26), wc[1] + sq(120)), (wc[0] + sq(10), wc[1] + sq(130))], fill=mark)

base = img.resize((1024, 1024), Image.LANCZOS)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "AppIcon.iconset")
os.makedirs(out, exist_ok=True)
for size in [16, 32, 128, 256, 512]:
    base.resize((size, size), Image.LANCZOS).save(os.path.join(out, f"icon_{size}x{size}.png"))
    base.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(out, f"icon_{size}x{size}@2x.png"))
base.save("/tmp/icon_preview.png")
print("ok")
