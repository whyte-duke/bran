#!/bin/zsh
#
# Fabrique Resources/AppIcon.icns.
#
#   zsh Scripts/make-icon.sh
#
# **L'icône est dessinée, pas photographiée.** La version précédente réduisait un
# JPEG de 1,5 Mo aux dix paliers réclamés par macOS, avec `sips`. Son propre
# commentaire disait déjà pourquoi c'était faux :
#
#   « une icône dont les petites tailles sont de simples réductions est floue à
#     16 px. Le rendu correct demanderait un dessin simplifié pour chaque
#     palier. »
#
# C'était exact, et le résultat était pire que flou : trois yeux en relief noir
# sur un fond noir, illisibles en dessous de 64 points. Dans le Dock, à côté de
# vingt icônes colorées, l'application n'apparaissait pas.
#
# `RenderIcon.swift` fait ce que ce commentaire réclamait : il redessine la forme
# à chaque taille en CoreGraphics, et il simplifie par palier — l'iris ambre
# disparaît sous 128 points, l'œil entier sous 32, le dégradé sous 32. Ce qui
# reste à seize pixels est une silhouette, parce qu'une silhouette survit à la
# réduction et qu'un détail ne survit jamais.
#
# Conséquence pratique : il n'y a plus de fichier source à ne pas perdre.
# L'icône EST son code, elle se régénère, et elle pèse 346 Ko au lieu de 1,6 Mo.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
ICONSET="$WORK/AppIcon.iconset"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$ICONSET" "$ROOT/Resources"

echo "→ rendu des dix paliers"
swift "$ROOT/Scripts/RenderIcon.swift" "$ICONSET"

echo "→ assemblage"
iconutil -c icns -o "$ROOT/Resources/AppIcon.icns" "$ICONSET"

echo
echo "✓ Resources/AppIcon.icns ($(du -h "$ROOT/Resources/AppIcon.icns" | cut -f1))"
echo "  Reconstruire l'app pour la voir :  zsh Scripts/build-app.sh"
echo
echo "  macOS met les icônes en cache. Si le Finder montre encore l'ancienne :"
echo "    killall Dock Finder"
