#!/bin/zsh
#
# Fabrique le `.dmg` qu'on donne à quelqu'un d'autre.
#
# `build-app.sh` installe bran sur CETTE machine ; celui-ci prépare de quoi
# l'installer sur une AUTRE. La différence n'est pas cosmétique : sur une autre
# machine, l'application traverse Gatekeeper, et Gatekeeper ne juge pas le code —
# il juge la signature.
#
# ─────────────────────────────────────────────────────────────────────────────
# CE QUE LE DESTINATAIRE VERRA, SELON CE QU'ON A SIGNÉ
# ─────────────────────────────────────────────────────────────────────────────
#
# **Certificat local (`bran-dev`), le défaut.** Il ne vit que dans le trousseau
# de la machine qui l'a créé ; ailleurs, rien ne l'ancre à une autorité connue.
# Mesuré sur cette machine, sur l'application installée : `spctl -a` rend
# `rejected`. Le destinataire verra « bran ne peut pas être ouvert, car Apple ne
# peut pas vérifier qu'il ne contient pas de logiciel malveillant », et depuis
# macOS 15 le clic droit → Ouvrir ne suffit plus : il faut aller dans Réglages
# Système › Confidentialité et sécurité, descendre, et cliquer « Ouvrir quand
# même ». Ça marche, et ça demande d'expliquer à chaque personne un parcours qui
# ressemble à s'y méprendre à celui qu'on suit pour installer quelque chose de
# douteux.
#
# **Developer ID + notarisation.** Le destinataire double-clique, l'application
# s'ouvre. C'est le seul cas où « partager facilement » est vrai. Il faut un
# compte Apple Developer Program (99 €/an), un certificat « Developer ID
# Application », et un profil `notarytool` :
#
#   xcrun notarytool store-credentials bran-notary \
#       --apple-id vous@exemple.fr --team-id ABCDE12345 \
#       --password <mot-de-passe-pour-application>
#
#   BRAN_IDENTITY="Developer ID Application: … (ABCDE12345)" \
#   BRAN_NOTARY_PROFILE=bran-notary \
#   zsh Scripts/package-app.sh
#
# ─────────────────────────────────────────────────────────────────────────────
#
# **Ce qu'aucune signature ne dispensera de faire.** bran a besoin de
# l'Enregistrement de l'écran, du micro et de l'Accessibilité. Ces trois
# autorisations sont accordées par chaque personne, sur sa machine, dans les
# Réglages Système — la notarisation ne les donne pas, elle rend seulement
# possible d'ouvrir l'application pour qu'elle puisse les demander.

set -euo pipefail

APP_NAME="bran"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

IDENTITY="${BRAN_IDENTITY:-bran-dev}"
NOTARY_PROFILE="${BRAN_NOTARY_PROFILE:-}"
OUTPUT_DIR="${BRAN_OUTPUT:-$ROOT/dist}"

# ── Le mode est tranché ICI, avant la moindre minute de compilation ───────────
#
# Les deux variables se répondent, et une seule des deux renseignée est presque
# toujours une faute de frappe plutôt qu'une intention. Le contrôle était fait
# plus bas, après le build et après l'écrasement du `.dmg` précédent : on
# découvrait donc l'erreur quatre minutes plus tard, sans paquet distribuable et
# sans celui d'avant.
#
# Le cas silencieux était le pire des deux : un Developer ID SANS profil de
# notarisation produisait une image ni signée ni notarisée, puis affichait le
# message « certificat local » — qui décrit autre chose. On repartait avec un
# paquet qu'on croyait seulement à moitié fini alors qu'il était faux.
if [[ "$IDENTITY" == Developer\ ID* && -z "$NOTARY_PROFILE" ]]; then
  echo "✗ identité « $IDENTITY » sans BRAN_NOTARY_PROFILE."
  echo "  Un Developer ID sans notarisation ne s'ouvre pas mieux qu'un certificat local :"
  echo "  Gatekeeper exige le ticket d'Apple, pas seulement une signature reconnue."
  echo "  Créez le profil une fois pour toutes :"
  echo "    xcrun notarytool store-credentials bran-notary \\"
  echo "        --apple-id vous@exemple.fr --team-id ABCDE12345 --password <mdp-application>"
  exit 1
fi

if [[ -n "$NOTARY_PROFILE" && "$IDENTITY" != Developer\ ID* ]]; then
  echo "✗ notarisation demandée avec l'identité « $IDENTITY »."
  echo "  Apple ne notarise que ce qui est signé par un Developer ID Application."
  exit 1
fi

# Le bundle est monté à l'écart de `~/Applications` : ce script peut tourner
# pendant que bran enregistre une réunion, et écraser l'application en cours
# d'exécution la ferait quitter au milieu.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"

echo "→ construction et signature"
BRAN_DEST="$APP" BRAN_IDENTITY="$IDENTITY" zsh "$ROOT/Scripts/build-app.sh" release

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# **L'image se construit à l'écart et ne rejoint `dist/` qu'une fois finie.**
#
# Elle était écrite directement à sa place définitive, précédée d'un `rm -f` :
# n'importe quel échec après cette ligne — `hdiutil`, la signature, un refus de
# notarisation, une coupure réseau pendant les quelques minutes d'examen —
# laissait `dist/` avec une image absente, tronquée, ou signée sans ticket. Or
# c'est précisément le fichier qu'on vient peut-être d'envoyer à trois personnes,
# et le seul exemplaire du dernier paquet qui marchait.
#
# Le brouillon vit **dans le dossier de sortie**, et non dans le dossier
# temporaire : le `mv` final n'est un renommage — donc instantané et atomique —
# que sur un même volume. `BRAN_OUTPUT` peut désigner un disque externe ou un
# partage réseau, et de là `mv` redeviendrait une copie de plusieurs mégaoctets,
# interruptible en son milieu, c'est-à-dire le défaut qu'on corrige.
DMG="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
mkdir -p "$OUTPUT_DIR"
# Le brouillon se termine par « .dmg », et pas par « .en-cours » : `hdiutil
# create` ajoute silencieusement l'extension quand elle manque, et écrivait donc
# à côté du chemin qu'on lui avait donné — le `mv` suivant cherchait ensuite un
# fichier qui n'existait pas, en laissant l'image sur le disque sous un nom que
# le nettoyage ne connaissait pas.
DRAFT="$OUTPUT_DIR/.$APP_NAME-$VERSION.en-cours.dmg"
rm -f -- "$DRAFT"
trap 'rm -rf "$STAGE"; rm -f -- "$DRAFT"' EXIT

# ── Le disque ────────────────────────────────────────────────────────────────
#
# Un `.dmg` plutôt qu'un `.zip`, pour deux raisons concrètes. Il porte l'alias
# vers `/Applications`, donc l'installation est un glisser-déposer que tout le
# monde connaît, sans instructions. Et il peut être **agrafé** (voir plus bas),
# ce qu'un `.zip` ne peut pas : le ticket de notarisation voyage alors avec le
# fichier, et la première ouverture ne dépend pas d'une connexion à Apple.

echo "→ image disque"
ROOM="$STAGE/dmg"
mkdir -p "$ROOM"
cp -R "$APP" "$ROOM/"
ln -s /Applications "$ROOM/Applications"

# ── La notice, DANS l'image ──────────────────────────────────────────────────
#
# Elle est écrite ici plutôt que rangée dans `Resources/` pour une seule raison,
# et elle est décisive : son contenu dépend de la façon dont le paquet vient
# d'être signé. Un fichier figé finirait par décrire un parcours qui n'est plus
# celui du paquet qu'il accompagne — c'est-à-dire par envoyer quelqu'un cliquer
# « Ouvrir quand même » sur une application notarisée qui s'ouvre toute seule, ou
# l'inverse, ce qui est bien pire.
#
# Le nom commence par « À » pour qu'elle se pose en tête du tri alphabétique du
# Finder, donc au-dessus de l'application : elle doit être lue AVANT le
# double-clic qui échoue, pas après.
NOTICE="$ROOM/À lire d'abord.txt"

{
  echo "bran — installation"
  echo "==================="
  echo
  echo "1. Glissez bran sur le dossier Applications, à côté."
  echo

  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "2. Ouvrez-le. C'est tout."
  else
    cat <<'FIN'
2. Ouvrez-le.

   Si macOS affiche « bran ne peut pas être ouvert car Apple ne peut pas
   vérifier qu'il ne contient pas de logiciel malveillant » :

     • ouvrez Réglages Système › Confidentialité et sécurité
     • descendez tout en bas de la page
     • cliquez « Ouvrir quand même », puis relancez bran

   Cet avertissement ne dit rien du contenu de l'application : il dit
   qu'elle n'a pas été soumise à Apple pour vérification. C'est le cas de
   bran aujourd'hui, qui est diffusé en interne et pas sur l'App Store.

   Comment l'éviter, souvent : cet avertissement se déclenche sur une
   marque « téléchargé » que macOS pose sur le fichier. Un lien de
   téléchargement, AirDrop, un mail ou un message la posent ; une copie
   directe par clé USB ou disque externe, non. Un partage réseau ou un NAS,
   ça dépend de sa configuration.

   Pour savoir avant d'essayer, dans le Terminal :

       xattr ~/Downloads/bran-VERSION.dmg

   Si « com.apple.quarantine » n'apparaît pas dans la liste, l'avertissement
   ne devrait pas se présenter. S'il apparaît, refaites-vous passer le
   fichier autrement, ou suivez les trois puces ci-dessus — les deux
   marchent.
FIN
  fi

  cat <<'FIN'

3. Au premier lancement, bran demandera trois autorisations. Elles sont
   accordées dans Réglages Système › Confidentialité et sécurité, et
   aucune n'est facultative :

     • Enregistrement de l'écran   pour filmer les réunions
     • Microphone                  pour votre voix, en réunion et en dictée
     • Accessibilité               pour le raccourci clavier et le collage

   L'écran d'accueil de bran les rappelle et dit lesquelles manquent.

4. bran vit dans la barre de menus, en haut à droite. Il n'enregistre
   jamais de lui-même : il propose quand il reconnaît une réunion, et
   c'est vous qui décidez.
FIN
} > "$NOTICE"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$ROOM" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DRAFT"

# ── La notarisation ──────────────────────────────────────────────────────────

if [[ -n "$NOTARY_PROFILE" ]]; then
  # L'image est signée elle aussi. Sans ça, `stapler` n'aurait rien où poser son
  # agrafe, et le destinataire dépendrait d'un aller-retour vers Apple à la
  # première ouverture — c'est-à-dire d'être connecté, ce qu'on ne contrôle pas.
  echo "→ signature de l'image"
  codesign --force --sign "$IDENTITY" --timestamp "$DRAFT"

  echo "→ notarisation (Apple examine le paquet ; comptez quelques minutes)"
  xcrun notarytool submit "$DRAFT" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "→ agrafage du ticket"
  xcrun stapler staple "$DRAFT"

  echo "→ vérification, telle que Gatekeeper la fera chez le destinataire"
  xcrun stapler validate "$DRAFT"
  spctl -a -t open --context context:primary-signature -vvv "$DRAFT" 2>&1 | sed 's/^/  /'
fi

# Tout ce qui pouvait échouer a réussi : l'image peut prendre sa place.
mv -f "$DRAFT" "$DMG"

# ── Le compte rendu ──────────────────────────────────────────────────────────
#
# Il dit ce que le destinataire VIVRA, pas ce que le script a fait. Un « ✓
# terminé » sur un paquet que personne ne pourra ouvrir sans un détour par les
# Réglages Système serait le pire des comptes rendus : exact et trompeur.

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ $DMG ($SIZE)"
echo

if [[ -n "$NOTARY_PROFILE" ]]; then
  cat <<'FIN'
  Signé par un Developer ID et notarisé par Apple.

  Le destinataire ouvre le .dmg, glisse bran dans Applications, et lance —
  aucune manipulation, aucun avertissement.

  Il devra en revanche accorder lui-même, dans Réglages Système ›
  Confidentialité et sécurité :
    • Enregistrement de l'écran   (les réunions)
    • Microphone                  (les réunions, la dictée)
    • Accessibilité               (le raccourci global et le collage)
  bran les demande au premier lancement et son écran d'accueil les rappelle.
FIN
else
  cat <<'FIN'
  ⚠︎ Signé avec le certificat LOCAL, non notarisé.

  L'image contient « À lire d'abord.txt », qui explique le reste au
  destinataire.

  Elle sort d'ici SANS marque de quarantaine — `xattr` sur le fichier le
  montre. C'est le mode de transport qui décide de la suite : un lien de
  téléchargement, AirDrop, un mail ou un message la posent ; une clé USB ou
  un disque externe, non ; un partage réseau ou un NAS, ça dépend de sa
  configuration. Sans cette marque, l'alerte Gatekeeper « développeur non
  vérifié » ne devrait pas se présenter.

  « Ne devrait pas », et pas « ne se présentera pas » : ça n'a pas pu être
  mesuré ici, faute d'un second Mac, et macOS conserve d'autres contrôles à
  la première ouverture. La notice donne au destinataire de quoi vérifier
  lui-même (`xattr`) plutôt qu'une promesse, et le parcours à suivre dans
  l'autre cas.

  Pour que la question ne se pose jamais, il faut un Developer ID et la
  notarisation — voir l'en-tête de ce fichier.
FIN
fi
