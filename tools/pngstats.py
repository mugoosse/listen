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
  shells  how many pixels fall in each shell's colour, in the order
          people/notes/chats/recordings. A shell that is not drawn scores
          zero, which is the only check that proves one is drawn at all.
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
    elif mode == 'pixel':
        # One pixel, for comparing two regions that should be the same colour.
        x, y = int(sys.argv[3]), int(sys.argv[4])
        i = (y * w + x) * 4
        print(px[i], px[i+1], px[i+2])
    elif mode == 'shells':
        # Which shells are drawn, by colour. These mirror
        # `GalaxyRenderer.starColor`, and they are matched on chromaticity
        # rather than on the raw values because the shader scales every star by
        # a brightness and a shimmer: a dim recording and a bright one are the
        # same hue at different lengths.
        targets = [
            ('people',     (1.00, 0.80, 0.28)),
            ('notes',      (0.36, 0.52, 1.00)),
            ('chats',      (0.85, 0.42, 1.00)),
            ('recordings', (0.20, 0.88, 0.74)),
            # The centre, which is bright enough to swamp any shell it is
            # mistaken for. Counted separately and then discarded.
            ('centre',     (1.00, 0.93, 0.74)),
            # And the links, which cross the whole picture and are deliberately
            # neither of any shell's colours. Counted so they are not mistaken
            # for one, then discarded.
            ('links',      (0.62, 0.68, 0.80)),
            # The decorative sky. Neutral for the same reason the links are:
            # every hue in this scene belongs to a shell.
            ('sky',        (0.58, 0.62, 0.70)),
        ]
        def chroma(c):
            total = sum(c) or 1.0
            return tuple(v / total for v in c)
        normed = [(name, chroma(rgb)) for name, rgb in targets]
        counts = {name: 0 for name, _ in targets}
        for i in range(0, len(px), 4):
            r, g, b = px[i], px[i+1], px[i+2]
            # Above the sky, and not so grey that the hue is noise.
            if r + g + b < 150 or max(r, g, b) - min(r, g, b) < 25:
                continue
            here = chroma((r, g, b))
            name, distance = min(
                ((n, sum((a - c) ** 2 for a, c in zip(here, t))) for n, t in normed),
                key=lambda pair: pair[1])
            if distance < 0.006:
                counts[name] += 1
        print(' '.join(str(counts[name]) for name, _ in targets[:4]))
