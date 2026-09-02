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
# L'empreinte du binaire **extrait**, pas seulement de l'archive.
#
# Elle n'est pas publiée par le projet kopia : elle est dérivée de l'archive
# ci-dessus, une fois celle-ci vérifiée contre son empreinte officielle. C'est
# la même chaîne de confiance, prolongée d'un cran — et ce cran manquait.
#
# Relevée le 02/09/2026 en téléchargeant l'archive épinglée, en confirmant son
# SHA-256, puis en hachant le `kopia` qu'elle contient. À refaire à chaque
# montée de version, par le même chemin.
BINARY_SHA256="2b73694b6cfc3bd064e4db744aa9e9674dc804997a67405351f43c95a9d274fa"

ROOT="${0:A:h:h}"
DEST="$ROOT/Vendor/kopia"
ARCHIVE="kopia-${VERSION}-macOS-arm64.tar.gz"
URL="https://github.com/kopia/kopia/releases/download/v${VERSION}/${ARCHIVE}"

# Déjà là et **authentique** : ne rien télécharger. Ce script est appelé par la
# construction, qui tourne des dizaines de fois par jour.
#
# **Le raccourci reposait sur `--version`, et c'était un trou.** Il exécutait le
# binaire trouvé sur place et l'acceptait dès que sa première sortie valait
# « 0.23.1 » — n'importe quel exécutable qui imprime cette chaîne passait. Or ce
# qui est accepté ici est ensuite copié dans le paquet par `build-app.sh`, puis
# **signé avec l'identité de bran** : un cache de construction empoisonné
# suffisait à produire une application valablement signée embarquant du code
# étranger, avec accès à l'écran, au micro et à tous les fichiers que
# l'utilisateur demande de sauvegarder.
#
# Le SHA-256 ne coûte que quelques centaines de millisecondes sur 46 Mo, et il
# se calcule **sans exécuter le fichier** — ce qui est l'autre moitié du
# problème : l'ancienne vérification lançait le binaire suspect pour décider
# s'il était digne de confiance.
if [[ -f "$DEST/kopia" ]]; then
  have=$(shasum -a 256 "$DEST/kopia" | cut -d' ' -f1)
  if [[ "$have" == "$BINARY_SHA256" ]]; then
    echo "→ kopia $VERSION déjà présent (empreinte vérifiée)"
    exit 0
  fi
  echo "→ kopia présent mais d'empreinte inattendue — remplacement"
  echo "   attendue : $BINARY_SHA256"
  echo "   obtenue  : $have"
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

# L'empreinte du binaire extrait, avant tout lancement. Sans ce contrôle, la
# constante `BINARY_SHA256` ne servirait qu'au raccourci du haut, et une montée
# de version qui oublierait de la mettre à jour laisserait passer en silence un
# binaire que le raccourci refuserait ensuite à chaque construction.
posee=$(shasum -a 256 "$DEST/kopia" | cut -d' ' -f1)
if [[ "$posee" != "$BINARY_SHA256" ]]; then
  echo "✗ le binaire extrait n'a pas l'empreinte épinglée."
  echo "  attendue : $BINARY_SHA256"
  echo "  obtenue  : $posee"
  echo "  L'archive est authentique mais son contenu a changé : mettez à jour"
  echo "  BINARY_SHA256 en connaissance de cause, ou arrêtez-vous ici."
  rm -f "$DEST/kopia"
  exit 1
fi

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
