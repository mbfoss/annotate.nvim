#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/annotate/util"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Only the neotoolkit modules annotate actually needs (transitive closure).
# annotate ships its own Explorer/Picker/etc. under lua/annotate, so those are
# not vendored, and `term` is deliberately excluded since nothing requires it.
FILES=(
    fileextmarks
    inputwin
    ui
    usercmd
)

cd "$(dirname "$0")/.."

if [[ -n "${LOCAL:-}" ]]; then
    echo "Using local repo: $LOCAL"
    cp -r "$LOCAL" "$TMP/neotoolkit"
else
    echo "Cloning $REPO..."
    git clone --depth=1 "$REPO" "$TMP/neotoolkit"
fi

SRC="$TMP/neotoolkit/lua/neotoolkit"

echo "Copying ${#FILES[@]} files into $DEST..."
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
    if [[ ! -f "$SRC/$f.lua" ]]; then
        echo "error: $f.lua not found in neotoolkit source" >&2
        exit 1
    fi
    cp "$SRC/$f.lua" "$DEST/$f.lua"
done

echo "Rewriting require paths and type annotations (neotoolkit. -> annotate.util.)..."
for f in "${FILES[@]}"; do
    sed -i '' 's/neotoolkit\./annotate.util./g' "$DEST/$f.lua"
done

echo "Done. Vendored ${#FILES[@]} modules into $DEST; annotate's own files are untouched."
