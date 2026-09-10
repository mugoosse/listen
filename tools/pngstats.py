#!/usr/bin/env python3
"""What is actually in a PNG, for `verify_galaxy.sh`.

A minimal decoder rather than Pillow, which a clean macOS does not have: a
verify script that needs `pip install` before it can check anything is a script
nobody runs. Three modes, and each one answers a question about the galaxy that
no other check can reach on a machine with a locked screen.

  size    the pixel dimensions
  bright  how many pixels are clearly brighter than the sky, which is the stars
          and the links: near zero is a black frame, and half the image is a
          renderer painting over everything
  hues    how many pixels fall in each shell's colour, in the order
          teal/orange/purple/blue, which is recordings, notes, chats, and
          people plus the centre. A shell that is not drawn scores zero.
"""
import struct, sys, zlib

def read(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos, idat, w, h, depth, colour = 8, b'', 0, 0, 0, 0
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos+8])
        body = data[pos+8:pos+8+length]
        if kind == b'IHDR':
            w, h, depth, colour = struct.unpack('>IIBB', body[:10])
        elif kind == b'IDAT':
            idat += body
        elif kind == b'IEND':
            break
        pos += 12 + length
    assert depth == 8 and colour == 6, f'expected 8-bit RGBA, got depth {depth} colour {colour}'
    raw = zlib.decompress(idat)
    stride = w * 4
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(4, stride): line[i] = (line[i] + line[i-4]) & 255
        elif f == 2:
            for i in range(stride): line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-4] if i >= 4 else 0
                b = prev[i]
                c = prev[i-4] if i >= 4 else 0
                pa, pb, pc = abs(b-c), abs(a-c), abs(a+b-2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, out

if __name__ == '__main__':
    path, mode = sys.argv[1], sys.argv[2]
    w, h, px = read(path)
    if mode == 'size':
        print(w, h)
    elif mode == 'bright':
        # Pixels clearly brighter than the sky, which is the star and line count.
        n = sum(1 for i in range(0, len(px), 4) if px[i] + px[i+1] + px[i+2] > 200)
        print(n)
    elif mode == 'hues':
        # Which shells are drawn, by their dominant channel. A recording is
        # green-dominant teal, a note is red-dominant orange, a chat is
        # purple with red under blue, a person and the centre are blue.
        teal = orange = purple = blue = 0
        for i in range(0, len(px), 4):
            r, g, b = px[i], px[i+1], px[i+2]
            if r + g + b < 150: continue
            if g > r + 30 and g > 60 and b > 40: teal += 1
            elif r > b + 40 and r > g + 20: orange += 1
            elif b > g + 40 and r > g + 10: purple += 1
            elif b > r + 30 and b > g: blue += 1
        print(teal, orange, purple, blue)
