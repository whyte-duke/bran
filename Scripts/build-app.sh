#!/bin/zsh
#
# Assemble bran.app, le signe avec `bran-dev` et l'installe dans ~/Applications.
#
# L'identifiant de bundle et l'identité de signature sont figés ici et nulle
# part ailleurs : c'est le couple auquel TCC attache l'autorisation
# « Enregistrement de l'écran ». Les changer révoque l'autorisation.

set -euo pipefail

BUNDLE_ID="com.opahventures.bran"
APP_NAME="bran"

# **L'identité est surchargeable, et changer d'identité a un prix qu'il faut
# connaître.**
#
# `bran-dev` est un certificat auto-signé qui ne vit que dans le trousseau de
# cette machine (voir `make-signing-identity.sh`). Il suffit pour travailler ici
# et il ne suffit pour rien d'autre : sur un autre Mac, Gatekeeper le rejette,
# parce que rien ne l'ancre à une autorité connue. Distribuer demande un
# « Developer ID Application », qui s'indique ici :
#
#   BRAN_IDENTITY="Developer ID Application: … (TEAMID)" zsh Scripts/build-app.sh
#
# **Ce que ça coûte, et le dire vaut mieux que le découvrir** : l'autorisation
# « Enregistrement de l'écran » de macOS est attachée à la signature. Passer de
# `bran-dev` au Developer ID la révoque sur CETTE machine, une fois — il faudra
# la redonner au premier lancement. Sur les machines qui reçoivent
# l'application, la question ne se pose pas : elles ne l'ont jamais accordée.
IDENTITY="${BRAN_IDENTITY:-bran-dev}"
# **`release` par défaut, et le défaut précédent était un vrai défaut.**
#
# Ce script n'est pas un script de compilation : il *installe* dans
# ~/Applications, c'est-à-dire qu'il livre l'application qu'on va utiliser toute
# la journée. Le défaut `debug` produisait donc un bundle signé, installé, et
# non optimisé — sans qu'aucune ligne de sa sortie ne le dise.
#
# Mesuré, sur la même machine et le même travail, à quinze secondes d'écart :
# 3,08 % de processeur au repos en debug, pics à 13,8 % ; 0,90 % en release,
# pics à 4,4 %. Le veilleur échantillonne des fenêtres et compare des blocs de
# pixels dans des boucles serrées, exactement le code qu'un build debug ne
# spécialise pas — le profil le montrait, à passer son temps dans
# `IndexingIterator.next()` et des témoins de protocole non spécialisés.
#
# `zsh Scripts/build-app.sh debug` reste disponible pour qui veut des symboles.
CONFIG="${1:-release}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)

# La destination est surchargeable, et ce n'est pas de la souplesse gratuite :
# sans ça, la seule façon de vérifier que ce script produit encore un bundle
# valide est d'écraser l'application installée — donc de la faire quitter, alors
# qu'elle est peut-être en train d'enregistrer une réunion.
#
#   BRAN_DEST=/tmp/essai.app zsh Scripts/build-app.sh
DEST="${BRAN_DEST:-$HOME/Applications/$APP_NAME.app}"

# **Garde-fou : la destination est effacée par `rm -rf`, quelques lignes plus
# bas.** Tant qu'elle était figée, ça n'engageait rien ; depuis qu'elle est
# surchargeable, une variable mal écrite — `BRAN_DEST=$HOME/Applications`, sans
# le `.app`, ou une variable vide qui laisse `BRAN_DEST=` — effacerait un dossier
# entier sans poser de question. Exiger le suffixe `.app` ne coûte rien et rend
# la faute impossible : aucun dossier qu'on tient à garder ne s'appelle ainsi.
if [[ "$DEST" != *.app ]]; then
  echo "✗ destination refusée : « $DEST »."
  echo "  BRAN_DEST doit désigner un bundle, donc se terminer par « .app »."
  exit 1
fi

cd "$ROOT"

if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "✗ identité de signature « $IDENTITY » absente."
  echo "  Lancez d'abord : zsh Scripts/make-signing-identity.sh"
  exit 1
fi

echo "→ compilation ($CONFIG)"
swift build -c "$CONFIG" --product BranApp
BINARY="$(swift build -c "$CONFIG" --product BranApp --show-bin-path)/BranApp"

echo "→ assemblage du bundle"
rm -rf -- "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BINARY" "$DEST/Contents/MacOS/$APP_NAME"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"
  ICON_ENTRY='    <key>CFBundleIconFile</key>          <string>AppIcon</string>'
else
  ICON_ENTRY=''
fi

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>bran</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
$ICON_ENTRY

    <!-- **Une application normale, que l'utilisateur peut démoter.**

         C'était <true/>, donc aucune icône dans le Dock. Mais BranApp.swift
         pose .defaultLaunchBehavior(.presented) sur la fenêtre principale :
         bran ouvrait donc une vraie fenêtre sans exister dans le Dock. On la
         fermait d'un ⌘W et le seul chemin de retour était la barre de menus,
         que rien n'annonce.

         L'inverse — une icône permanente — se retire depuis les réglages, où
         « Afficher dans le Dock » repose la politique d'activation. Le défaut
         qui se corrige d'un clic vaut mieux que celui qui n'a pas d'interface. -->
    <key>LSUIElement</key>               <false/>

    <!-- Textes affichés par macOS dans la fenêtre d'autorisation. Ils doivent
         dire à quoi sert la permission, pas la réclamer.

         **Les deux premiers manquaient**, et c'est le genre d'oubli qui ne se
         voit pas tant qu'on est seul sur sa machine : l'autorisation avait déjà
         été accordée ici, il y a des mois, et rien ne la redemandait. Sur le Mac
         de quelqu'un d'autre — c'est-à-dire au premier partage — macOS pose la
         question pour de bon, et une clé absente donne une fenêtre sans
         explication, sur la permission la plus intrusive qui soit : filmer
         l'écran et écouter ce qui s'y joue. -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>bran filme votre écran pendant les réunions que vous choisissez d'enregistrer, et rien d'autre : l'enregistrement ne démarre que sur votre geste et s'arrête avec la réunion.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>bran enregistre le son de la réunion — la voix de vos interlocuteurs — en même temps que l'écran, pour que le compte rendu puisse être transcrit.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>bran enregistre votre voix pendant les réunions, et pendant la dictée pour la transcrire sur votre Mac.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>bran lit l'événement en cours pour donner son titre et ses participants à l'enregistrement.</string>

    <!-- Il y avait ici un NSAppleEventsUsageDescription annonçant que bran
         « colle le texte dicté dans l'application où se trouve votre curseur ».
         Le texte décrivait bien ce que fait la dictée, mais pas par quel moyen :
         Paster.swift écrit dans le presse-papiers puis poste un ⌘V par CGEvent,
         et le dépôt ne contient pas un seul Apple Event. La clé annonçait donc
         une capacité de pilotage inter-application inexistante — à
         l'utilisateur, et à qui inspecte le paquet.

         (Pas d'accents graves dans ce commentaire : ce bloc est un heredoc zsh
         non protégé — il doit interpoler $APP_NAME et $BUNDLE_ID — donc tout ce
         qu'ils encadreraient serait exécuté comme une commande.) -->
</dict>
</plist>
PLIST

# **Le renforcement n'est posé qu'avec un Developer ID, et c'est délibéré.**
#
# Apple exige l'« environnement d'exécution renforcé » pour notariser, et la
# notarisation n'est possible qu'avec un Developer ID : les deux vont ensemble.
# L'imposer aussi au certificat local coûterait une différence de comportement
# entre ce qu'on essaie tous les jours et ce qu'on distribue — un droit oublié
# dans `bran.entitlements` ne se verrait alors qu'après l'envoi.
#
# Le revers est accepté et vaut d'être écrit : la version locale tourne SANS
# renforcement, donc un droit manquant ne se manifeste qu'au premier paquet
# signé pour de bon. C'est ce que `package-app.sh` vérifie, en installant le
# résultat notarisé sur cette machine avant de le donner à qui que ce soit.
SIGN_FLAGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID")

if [[ "$IDENTITY" == Developer\ ID* ]]; then
  ENTITLEMENTS="$ROOT/Resources/bran.entitlements"
  if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "✗ $ENTITLEMENTS est introuvable — un binaire renforcé sans droits n'aurait ni micro ni collage."
    exit 1
  fi
  # `--timestamp` interroge le serveur d'horodatage d'Apple : sans lui, la
  # signature cesserait d'être valable le jour où le certificat expire, y
  # compris sur les copies déjà distribuées.
  SIGN_FLAGS+=(--options runtime --timestamp --entitlements "$ENTITLEMENTS")
  echo "→ signature ($IDENTITY, environnement renforcé)"
else
  SIGN_FLAGS+=(--timestamp=none)
  echo "→ signature ($IDENTITY, usage local)"
fi

codesign "${SIGN_FLAGS[@]}" "$DEST"

# LaunchServices garde l'icône en cache : sans ce ré-enregistrement, le Finder
# et le centre de notifications continuent d'afficher l'icône générique.
echo "→ ré-enregistrement auprès de LaunchServices (cache d'icônes)"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" 2>/dev/null || true
touch "$DEST"

echo "→ vérification"
codesign --verify --deep --strict --verbose=2 "$DEST" 2>&1 | sed 's/^/  /'

echo
echo "✓ installé : $DEST"
echo "  Lancer :   open \"$DEST\""
echo
echo "  Si les autorisations ont été accordées à une ancienne signature :"
echo "    tccutil reset ScreenCapture $BUNDLE_ID"
echo "    tccutil reset Microphone    $BUNDLE_ID"
echo "    tccutil reset Calendar      $BUNDLE_ID"
