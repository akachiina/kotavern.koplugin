#!/usr/bin/env python3
"""Merge Noto Emoji into the chat font faces (assets/sans-x-*.ttf).

MuPDF does NOT do per-glyph fallback across a font-family list: the first
existing family renders the whole run and every missing glyph becomes a
tofu box (probe: the old KTEmoji-chain "emoji ink" was the tofu outline -
the U+E000 control exposed it). The only real fix is ONE face with ALL the
glyphs: each output is the Noto Sans weight + Noto Emoji (monochrome)
merged into a single cmap.

Pipeline per emoji source: instantiate the variable font to static, strip
variable/vertical/optional tables (Merger chokes on fvar/STAT/vhea), scale
to the Sans unitsPerEm, then fontTools Merger.

Run from the repo root:  python3 tools/merge_emoji_font.py
Requires fonttools (>= 4.28 for scale_upem).
"""
import os
import tempfile

from fontTools.merge import Merger
from fontTools.ttLib import TTFont
from fontTools.ttLib.scaleUpem import scale_upem
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
PAIRS = [
    ("sans-regular.ttf", "sans-x-regular.ttf"),
    ("sans-bold.ttf", "sans-x-bold.ttf"),
    ("sans-italic.ttf", "sans-x-italic.ttf"),
]
# Tables the Merger cannot reconcile across these two families (variable
# metadata, vertical metrics) or that the chat never uses.
STRIP = ("fvar", "gvar", "HVAR", "VVAR", "STAT", "avar", "vhea", "vmtx")


def main():
    sans = TTFont(os.path.join(ASSETS, "sans-regular.ttf"), lazy=True)
    upem = sans["head"].unitsPerEm
    sans.close()

    emoji = TTFont(os.path.join(ASSETS, "emoji-noto.ttf"))
    instantiateVariableFont(emoji, {}, inplace=True)
    for tag in STRIP:
        if tag in emoji:
            del emoji[tag]
    scale_upem(emoji, upem)
    fd, tmp_emoji = tempfile.mkstemp(suffix=".ttf")
    os.close(fd)
    emoji.save(tmp_emoji)
    emoji.close()

    for base_name, out_name in PAIRS:
        base = os.path.join(ASSETS, base_name)
        out = os.path.join(ASSETS, out_name)
        merged = Merger().merge([base, tmp_emoji])
        merged.save(out)
        f = TTFont(out, lazy=True)
        cmap = f.getBestCmap()
        assert 0x41 in cmap and 0x1F602 in cmap and 0x2705 in cmap, out_name
        print(
            "%s: %d glyphs, %.2f MB" % (out_name, f["maxp"].numGlyphs,
                                        os.path.getsize(out) / 1e6)
        )
        f.close()
    os.unlink(tmp_emoji)


if __name__ == "__main__":
    main()
