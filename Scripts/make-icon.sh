#!/bin/zsh
#
# Fabrique Resources/AppIcon.icns à partir d'une image carrée.
#
#   zsh Scripts/make-icon.sh mon-icone.png
#
# Les dix tailles requises par macOS sont générées par `sips`, pas à la main :
# une icône dont les petites tailles sont de simples réductions est floue à
# 16 px. Le rendu correct demanderait un dessin simplifié pour chaque palier —
# c'est ce que fait Icon Composer. Ici on fait au mieux automatiquement, ce qui
# suffit tant que la marque reste une forme simple et contrastée.

set -euo pipefail

SOURCE="${1:-}"
if [[ -z "$SOURCE" || ! -f "$SOURCE" ]]; then
  echo "usage : zsh Scripts/make-icon.sh <image carrée .png|.jpeg>"
  exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
ICONSET="$WORK/AppIcon.iconset"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$ICONSET" "$ROOT/Resources"

# sips ne lit correctement que du PNG pour ce genre d'enchaînement.
sips -s format png "$SOURCE" --out "$WORK/source.png" >/dev/null

DIMENSIONS=(16 32 64 128 256 512 1024)
for size in $DIMENSIONS; do
  sips -z $size $size "$WORK/source.png" --out "$WORK/$size.png" >/dev/null
done

cp "$WORK/16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK/32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK/32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK/64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK/128.png"  "$ICONSET/icon_128x128.png"
cp "$WORK/256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$WORK/256.png"  "$ICONSET/icon_256x256.png"
cp "$WORK/512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$WORK/512.png"  "$ICONSET/icon_512x512.png"
cp "$WORK/1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "✓ Resources/AppIcon.icns"
echo "  Relancez : zsh Scripts/build-app.sh"
echo
echo "  Aperçu des petites tailles — c'est à celles-là qu'une icône se juge :"
echo "  $WORK/16.png, 32.png (copiés ci-dessous pour inspection)"
cp "$WORK/16.png" "$ROOT/Resources/apercu-16.png"
cp "$WORK/32.png" "$ROOT/Resources/apercu-32.png"
