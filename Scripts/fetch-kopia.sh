#!/bin/zsh
# Télécharge le binaire `kopia` que bran embarque, à une version épinglée.
#
# **Pourquoi un script plutôt qu'un binaire dans le dépôt.** 46 Mo par version,
# dans un dépôt dont tout le reste tient en texte. Git n'oublie jamais : trois
# montées de version et l'historique pèse 140 Mo que personne ne relira. Le
# binaire est donc gitignoré et reconstruit à la demande, comme les artefacts de
# SwiftPM.
#
# **Pourquoi ne pas prendre celui de Homebrew.** Il est là, il est le bon, et
# c'est exactement le problème : il change quand Homebrew décide, pas quand bran
# décide. Une application signée dont le moteur de sauvegarde peut muter sous
# elle entre deux constructions n'est pas reproductible — et le jour où un
# comportement change, on ne saurait pas dire quelle version l'a introduit. On
# épingle donc la version **et** son empreinte, et on les vérifie.
#
# **Pourquoi l'archive officielle et pas un miroir.** L'empreinte ci-dessous
# vient du `checksums.txt` publié par le projet à côté de l'archive. Elle est
# recopiée ici pour qu'une archive substituée en route soit refusée : télécharger
# la somme depuis la même source que le fichier ne vérifierait rien du tout.
#
# Mise à jour : changer VERSION et SHA256 (lus dans le `checksums.txt` de la
# nouvelle version), relancer ce script, puis `Scripts/package-app.sh` — qui
# resigne le binaire avec l'identité de bran.
set -euo pipefail

VERSION="0.23.1"
SHA256="19e6ed637221f4dfd46a46e978ec4c509c386b522d746db2cd6762b217478111"

ROOT="${0:A:h:h}"
DEST="$ROOT/Vendor/kopia"
ARCHIVE="kopia-${VERSION}-macOS-arm64.tar.gz"
URL="https://github.com/kopia/kopia/releases/download/v${VERSION}/${ARCHIVE}"

# Déjà là et à la bonne version : ne rien télécharger. Ce script est appelé par
# la construction, qui tourne des dizaines de fois par jour.
if [[ -x "$DEST/kopia" ]]; then
  have=$("$DEST/kopia" --version 2>/dev/null | awk '{print $1}') || have=""
  if [[ "$have" == "$VERSION" ]]; then
    echo "→ kopia $VERSION déjà présent"
    exit 0
  fi
  echo "→ kopia présent en version « ${have:-inconnue} », attendu $VERSION — remplacement"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "→ téléchargement de kopia $VERSION (arm64)"
curl -fsSL --retry 3 --max-time 300 -o "$work/$ARCHIVE" "$URL"

echo "→ vérification de l'empreinte"
actual=$(shasum -a 256 "$work/$ARCHIVE" | cut -d' ' -f1)
if [[ "$actual" != "$SHA256" ]]; then
  echo "✗ empreinte inattendue pour $ARCHIVE"
  echo "  attendue : $SHA256"
  echo "  obtenue  : $actual"
  echo "  L'archive n'est pas celle qui a été épinglée. On s'arrête."
  exit 1
fi

tar -xzf "$work/$ARCHIVE" -C "$work"
binary=$(find "$work" -type f -name kopia -perm -u+x | head -1)
if [[ -z "$binary" ]]; then
  echo "✗ aucun exécutable « kopia » dans l'archive."
  exit 1
fi

mkdir -p "$DEST"
cp "$binary" "$DEST/kopia"
chmod +x "$DEST/kopia"

# Vérifier que le binaire posé **s'exécute** et annonce la version attendue.
# Une archive valide contenant un binaire pour une autre architecture passerait
# toutes les vérifications ci-dessus et n'échouerait qu'au premier lancement
# réel, c'est-à-dire chez l'utilisateur.
got=$("$DEST/kopia" --version 2>&1 | awk '{print $1}')
if [[ "$got" != "$VERSION" ]]; then
  echo "✗ le binaire posé annonce « $got », attendu « $VERSION »."
  exit 1
fi

echo "✓ kopia $VERSION dans Vendor/kopia/ ($(du -h "$DEST/kopia" | cut -f1))"
