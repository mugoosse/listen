#!/usr/bin/env python3
"""Label actual native Metal frames and encode a silent, real-time preview.
Requires Pillow and ffmpeg; drawtext support is not required.
"""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFont

here = Path(__file__).resolve().parent
results = here / 'results'
frames = results / 'shell-frames'
files = sorted(frames.glob('frame-*.png'))
assert len(files) == 240, f'Expected 240 actual exported frames, found {len(files)}'
assert all(path.name == f'frame-{index:04d}.png' for index, path in enumerate(files))
canvas = Image.new('RGBA', (1280, 800))
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 17)
small = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 14)
draw.text((30, 26), 'LISTEN GALAXY  /  SYNTHETIC METAL PREVIEW', font=font, fill=(187, 203, 224, 255))
x = 30
for label, color in [('People', '#45b3ff'), ('Notes', '#ffb84d'), ('Ask conversations', '#b06eff'), ('Recordings', '#33e0bd')]:
    draw.ellipse((x, 756, x + 6, 762), fill=color)
    draw.text((x + 14, 750), label, font=small, fill=(168, 185, 205, 255))
    x += int(draw.textlength(label, font=small)) + 44
canvas.save(results / 'preview-overlay.png')
frame = Image.open(files[0]).convert('RGBA')
frame.alpha_composite(canvas)
frame.convert('RGB').save(results / 'listen-galaxy-shells.jpg', quality=95)
subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
                '-framerate', '30', '-i', str(frames / 'frame-%04d.png'),
                '-i', str(results / 'preview-overlay.png'), '-filter_complex', '[0:v][1:v]overlay=0:0',
                '-frames:v', '240', '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p',
                '-movflags', '+faststart', '-an', str(results / 'listen-galaxy-shells.mp4')], check=True)
print(results / 'listen-galaxy-shells.mp4')
