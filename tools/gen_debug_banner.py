#!/usr/bin/env python3
"""Regenerate assets/debug_banner/frame_*.png from assets/sonic_debug.gif.

KOReader's giflib wrapper renders RAW GIF frames: delta sub-rects get scaled
to the full canvas and the transparency index is flattened to white, so an
animated GIF with delta encoding can never play correctly through
RenderImage (only frame 0 shows the body; the rest show the moving part
alone on a white box).

This script pre-composites the frames the way a correct GIF player would
(PIL implements GIF disposal/delta semantics) and ships them as plain full
RGBA frames that ktui/gifanim.lua can flip through. Run from the repo root:

    python3 tools/gen_debug_banner.py

Requires Pillow (python3 -m pip install pillow).
"""

import os
import sys

try:
    from PIL import Image, ImageSequence
except ImportError:
    sys.exit("Pillow is required: python3 -m pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "sonic_debug.gif")
OUT_DIR = os.path.join(ROOT, "assets", "debug_banner")
LONG_SIDE = 320  # display size is ~150px; keep some headroom, stay small


def main():
    im = Image.open(SRC)
    os.makedirs(OUT_DIR, exist_ok=True)
    for old in os.listdir(OUT_DIR):
        if old.endswith(".png"):
            os.remove(os.path.join(OUT_DIR, old))

    count = 0
    for frame in ImageSequence.Iterator(im):
        rgba = frame.convert("RGBA")  # PIL composites deltas/disposal for us
        rgba.thumbnail((LONG_SIDE, LONG_SIDE), Image.LANCZOS)
        count += 1
        out = os.path.join(OUT_DIR, "frame_%d.png" % count)
        rgba.save(out)
        # Quick sanity print: opaque pixel share (a flattened/empty frame
        # would be ~0 here because transparent pixels keep alpha=0).
        alpha = rgba.getchannel("A")
        opaque = sum(1 for v in alpha.getdata() if v > 0)
        print("frame_%d.png %s opaque=%d/%d" % (count, rgba.size, opaque, rgba.size[0] * rgba.size[1]))

    if count < 2:
        sys.exit("source animation has fewer than 2 frames")
    print("wrote %d frames to %s" % (count, OUT_DIR))


if __name__ == "__main__":
    main()
