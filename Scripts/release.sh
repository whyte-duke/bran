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

# `gh` est vérifié ici, avant la garde de version : celle-ci interroge GitHub
# pour savoir ce qui a réellement été publié.
command -v gh >/dev/null || { echo "✗ « gh » est absent."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ « gh » n'est pas authentifié : gh auth login"; exit 1; }

# **Une version ne recule pas.** Sparkle compare les numéros : republier sous un
# numéro inférieur ou égal à celui déjà installé produit une release que
# personne ne recevra jamais, sans message d'erreur nulle part — le cas le plus
# désagréable, puisqu'on croit avoir livré.
CURRENT=$(cat VERSION 2>/dev/null || echo "0.0.0")
LOWEST=$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | head -1)

# **La reprise après échec, qui était impossible.**
#
# `VERSION` était écrit avant la construction. Si `package-app.sh` échouait —
# ou l'appcast, ou un `git push` —, le fichier restait modifié, `CURRENT`
# valait déjà le numéro visé, et relancer la même commande se faisait refuser
# par cette garde-ci comme « pas postérieure ». Il fallait deviner qu'un
# `git checkout VERSION` débloquait tout.
#
# Pire, l'échec pouvait survenir **après** les deux `git push` : le dépôt
# distant portait alors un commit et une étiquette sans image disque ni flux.
# Or une version cassée qui s'installe toute seule ne se rattrape pas à
# distance — une application qui ne démarre plus ne peut plus se mettre à
# jour. L'état intermédiaire est donc ce qu'il faut le plus pouvoir reprendre.
#
# On demande donc à GitHub ce qui existe vraiment, plutôt que de le déduire du
# fichier local.
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  ALREADY_PUBLISHED=1
else
  ALREADY_PUBLISHED=0
fi

if [[ "$VERSION" == "$CURRENT" && "$ALREADY_PUBLISHED" == "1" ]]; then
  echo "✗ « $VERSION » est déjà publiée sur GitHub."
  echo "  Republier sous le même numéro ne proposerait rien à personne :"
  echo "  Sparkle compare les numéros. Passez au numéro suivant."
  exit 1
fi

if [[ "$VERSION" == "$CURRENT" ]]; then
  echo "→ reprise : VERSION porte déjà « $VERSION », aucune publication n'existe."
elif [[ "$LOWEST" == "$VERSION" ]]; then
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

# L'outil de Sparkle est livré par SwiftPM, sous un chemin qui contient sa
# version. Résolu par motif pour la même raison que le framework dans
# `build-app.sh` : l'écrire en dur casserait à la prochaine montée de version.
APPCAST_TOOL=$(find "$ROOT/.build/artifacts" -type f -name "generate_appcast" 2>/dev/null | head -1)
if [[ -z "$APPCAST_TOOL" ]]; then
  echo "✗ « generate_appcast » introuvable. Lancez : swift package resolve"
  exit 1
fi

echo "→ version $CURRENT → $VERSION"

# **Tant que rien n'est parti, rien ne reste.**
#
# `VERSION` est modifié ici, et tout ce qui suit peut échouer. Le piège
# restaure le fichier tel qu'il était, pour qu'un échec ne laisse pas l'arbre
# dans un état qui bloque la reprise. Il est désarmé au moment exact où la
# modification devient légitime : le commit.
VERSION_BEFORE=$(cat VERSION 2>/dev/null || echo "")
restaurer_version() {
  if [[ -n "$VERSION_BEFORE" ]]; then
    printf '%s\n' "$VERSION_BEFORE" > VERSION
  fi
  echo
  echo "✗ publication interrompue. VERSION a été remis à « $VERSION_BEFORE »."
  echo "  Rien n'a été poussé : relancez la même commande une fois la cause levée."
}
trap restaurer_version ERR INT TERM

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

# Le point de non-retour : à partir d'ici, la modification de VERSION est dans
# l'historique et il n'y a plus rien à restaurer. Le piège serait nuisible —
# il réécrirait un fichier déjà commité.
trap - ERR INT TERM

# **`tag -f` et `push -f` sont retirés, et ce n'était pas du confort.**
#
# Forcer une étiquette déjà poussée déplace ce que `v$VERSION` désigne sur les
# machines qui l'ont déjà récupérée. Sur un canal de mise à jour automatique,
# c'est la seule chose qu'on ne doit jamais faire : deux personnes peuvent
# alors avoir installé deux binaires différents sous le même numéro, et plus
# rien ne permet de dire lequel tourne où.
EXISTING_TAG=$(git rev-parse -q --verify "refs/tags/v$VERSION" || true)
HEAD_SHA=$(git rev-parse HEAD)
if [[ -z "$EXISTING_TAG" ]]; then
  git tag "v$VERSION" >/dev/null
elif [[ "$EXISTING_TAG" != "$HEAD_SHA" ]]; then
  echo "✗ l'étiquette « v$VERSION » existe déjà et désigne un autre commit."
  echo "    étiquette : $EXISTING_TAG"
  echo "    HEAD      : $HEAD_SHA"
  echo "  La déplacer changerait ce que désigne une version déjà distribuée."
  echo "  Publiez sous le numéro suivant."
  exit 1
fi

git push origin main >/dev/null
git push origin "v$VERSION" >/dev/null

echo "→ publication GitHub"
# Idempotent : un échec après les pushes laissait un commit et une étiquette
# sans release, et relancer butait sur « release already exists ».
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "  (la release existe déjà — remplacement des fichiers)"
  gh release upload "v$VERSION" \
    --repo "$REPO" --clobber \
    "$DMG" \
    "$ROOT/dist/appcast.xml"
else
  gh release create "v$VERSION" \
    --repo "$REPO" \
    --title "bran $VERSION" \
    --notes "Mise à jour automatique. bran l'installe en fond et proposera de relancer." \
    "$DMG" \
    "$ROOT/dist/appcast.xml"
fi

echo
echo "✓ bran $VERSION publiée"
echo
echo "  Les machines de l'équipe la verront dans l'heure, l'installeront en fond,"
echo "  et afficheront « Une mise à jour est prête ». Rien à faire de votre côté."
echo
echo "  Flux : https://github.com/$REPO/releases/latest/download/appcast.xml"
