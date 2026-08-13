#!/bin/zsh
#
# Publie une version. C'est la seule commande à lancer après avoir amélioré
# quelque chose :
#
#   zsh Scripts/release.sh 0.1.1
#
# Elle enchaîne : numéro de version → construction → image disque → flux de
# mise à jour signé → publication GitHub. Les machines de l'équipe voient la
# nouvelle version dans l'heure, l'installent en fond, et proposent de relancer.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUI PROTÈGE CE CANAL
# ─────────────────────────────────────────────────────────────────────────────
#
# Une mise à jour automatique installe ce qu'on lui donne, sur des machines qui
# ont déjà accordé à bran l'accès à l'écran, au micro et au clavier. C'est le
# mécanisme le plus dangereux de toute l'application, et le seul qui mérite deux
# verrous plutôt qu'un :
#
# - **HTTPS et GitHub** garantissent d'où vient le fichier ;
# - **la signature EdDSA** garantit qui l'a fabriqué. La clé privée vit dans le
#   trousseau de cette machine et n'en sort pas ; bran refuse toute archive
#   qu'elle n'a pas signée. Un compte GitHub compromis ne suffit donc pas à
#   pousser un binaire sur le Mac de quelqu'un.
#
# Sans le second, publier une release deviendrait équivalent à obtenir un accès
# à distance sur trois machines.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REPO="whyte-duke/bran"
APP_NAME="bran"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "✗ numéro de version manquant."
  echo "  Usage : zsh Scripts/release.sh 0.1.1"
  echo "  Version actuelle : $(cat VERSION 2>/dev/null || echo '—')"
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ « $VERSION » n'est pas un numéro de version (attendu : 1.2.3)."
  exit 1
fi

# **Une version ne recule pas.** Sparkle compare les numéros : republier sous un
# numéro inférieur ou égal à celui déjà installé produit une release que
# personne ne recevra jamais, sans message d'erreur nulle part — le cas le plus
# désagréable, puisqu'on croit avoir livré.
CURRENT=$(cat VERSION 2>/dev/null || echo "0.0.0")
LOWEST=$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | head -1)
if [[ "$VERSION" == "$CURRENT" || "$LOWEST" == "$VERSION" ]]; then
  echo "✗ « $VERSION » n'est pas postérieure à la version actuelle « $CURRENT »."
  echo "  Sparkle ne proposerait cette publication à personne."
  exit 1
fi

# **Ce qu'on publie doit être ce qui est dans l'historique.** Publier depuis un
# arbre modifié met sur les machines de l'équipe du code qui n'existe nulle part
# ailleurs : le jour où il faut comprendre un défaut, la version installée ne
# correspond à aucun commit, et il n'y a rien à relire.
DIRTY=$(git status --porcelain -- Sources Scripts Resources Package.swift VERSION)
if [[ -n "$DIRTY" && "${BRAN_ALLOW_DIRTY:-}" != "1" ]]; then
  echo "✗ des modifications ne sont pas commitées :"
  echo "$DIRTY" | sed 's/^/    /'
  echo "  Committez-les, ou forcez avec BRAN_ALLOW_DIRTY=1 en sachant que la"
  echo "  version publiée ne correspondra à aucun commit."
  exit 1
fi

command -v gh >/dev/null || { echo "✗ « gh » est absent."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ « gh » n'est pas authentifié : gh auth login"; exit 1; }

# L'outil de Sparkle est livré par SwiftPM, sous un chemin qui contient sa
# version. Résolu par motif pour la même raison que le framework dans
# `build-app.sh` : l'écrire en dur casserait à la prochaine montée de version.
APPCAST_TOOL=$(find "$ROOT/.build/artifacts" -type f -name "generate_appcast" 2>/dev/null | head -1)
if [[ -z "$APPCAST_TOOL" ]]; then
  echo "✗ « generate_appcast » introuvable. Lancez : swift package resolve"
  exit 1
fi

echo "→ version $CURRENT → $VERSION"
echo "$VERSION" > VERSION

# **Le dossier est vidé, et c'est nécessaire.** `generate_appcast` décrit TOUT
# ce qu'il trouve : une image d'une version précédente restée là ressortirait
# dans le flux, avec sa signature, et resterait proposée indéfiniment.
rm -rf "$ROOT/dist"

echo "→ construction et image disque"
zsh "$ROOT/Scripts/package-app.sh" >/dev/null

DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "✗ image attendue introuvable : $DMG"; exit 1; }

# L'adresse à laquelle les fichiers seront servis une fois la release créée.
# Elle doit être écrite dans le flux AVANT la publication, puisque c'est le flux
# lui-même qui la contient.
echo "→ flux de mise à jour, signé"
"$APPCAST_TOOL" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  "$ROOT/dist"

[[ -f "$ROOT/dist/appcast.xml" ]] || { echo "✗ appcast.xml non produit."; exit 1; }

# La signature est vérifiée ici plutôt que découverte par un utilisateur dont la
# mise à jour est refusée sans explication.
grep -q "edSignature" "$ROOT/dist/appcast.xml" || {
  echo "✗ le flux ne porte aucune signature EdDSA."
  echo "  La clé privée est-elle dans le trousseau ? (generate_keys)"
  exit 1
}

echo "→ commit et étiquette"
git add VERSION
git commit -m "Publier la version $VERSION" >/dev/null 2>&1 || echo "  (VERSION déjà à jour)"
git tag -f "v$VERSION" >/dev/null
git push origin main >/dev/null
git push -f origin "v$VERSION" >/dev/null

echo "→ publication GitHub"
gh release create "v$VERSION" \
  --repo "$REPO" \
  --title "bran $VERSION" \
  --notes "Mise à jour automatique. bran l'installe en fond et proposera de relancer." \
  "$DMG" \
  "$ROOT/dist/appcast.xml"

echo
echo "✓ bran $VERSION publiée"
echo
echo "  Les machines de l'équipe la verront dans l'heure, l'installeront en fond,"
echo "  et afficheront « Une mise à jour est prête ». Rien à faire de votre côté."
echo
echo "  Flux : https://github.com/$REPO/releases/latest/download/appcast.xml"
