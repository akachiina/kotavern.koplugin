#!/usr/bin/env bash
# Subsets a Nerd Font Symbols TTF down to the codepoints KOTavern's glyph
# fallback uses (ktui/icons.lua) and bundles it into the plugin:
#   fonts/nerdfonts/symbols.ttf
# (named/located so credocument.lua's engineInit skips it — nerd fonts can't
# register in crengine; see main.lua register_nerd_font).
#
# The bundled font makes icon glyph metrics deterministic across devices and
# covers glyphs missing from older KOReader builds' symbols.ttf (the global
# fallback chain picks it up via main.lua's register_nerd_font).
#
# Source font (override to use a newer SymbolsNerdFont release):
#   NERD_FONT_SOURCE=/path/to/SymbolsNerdFont-Regular.ttf ./tools/subset_nerd_font.sh
#
# Requires: pyftsubset (pip install fonttools)

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FONT_NAME="nerdfonts/symbols.ttf"
SOURCE_FONT="${NERD_FONT_SOURCE:-/usr/lib/koreader/fonts/nerdfonts/symbols.ttf}"

if ! command -v pyftsubset >/dev/null 2>&1; then
    echo "pyftsubset is required (pip install fonttools)" >&2
    exit 1
fi
if [ ! -f "$SOURCE_FONT" ]; then
    echo "Source font not found: $SOURCE_FONT" >&2
    echo "Set NERD_FONT_SOURCE=/path/to/SymbolsNerdFont-Regular.ttf" >&2
    exit 1
fi

unicode_list="$(mktemp "${TMPDIR:-/tmp}/kotavern-nerd-unicodes.XXXXXX")"
# Extract every codepoint from the glyph fallback map in ui/icons.lua.
sed -n '/^local map = {$/,/^}/s/.*0x\([0-9A-Fa-f][0-9A-Fa-f]*\).*/U+\1/p' \
    "$PLUGIN_DIR/ktui/icons.lua" > "$unicode_list"
if [ ! -s "$unicode_list" ]; then
    echo "No codepoints found in ui/icons.lua" >&2
    rm -f "$unicode_list"
    exit 1
fi

mkdir -p "$PLUGIN_DIR/fonts/nerdfonts"
pyftsubset "$SOURCE_FONT" \
    --unicodes-file="$unicode_list" \
    --output-file="$PLUGIN_DIR/fonts/$FONT_NAME" \
    --drop-tables+=PfEd \
    --name-IDs='*' \
    --name-languages='*'
rm -f "$unicode_list"

echo "subset_nerd_font: wrote fonts/$FONT_NAME ($(wc -c < "$PLUGIN_DIR/fonts/$FONT_NAME") bytes)"
