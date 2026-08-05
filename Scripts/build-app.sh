#!/bin/zsh
#
# Assemble bran.app, le signe avec `bran-dev` et l'installe dans ~/Applications.
#
# L'identifiant de bundle et l'identité de signature sont figés ici et nulle
# part ailleurs : c'est le couple auquel TCC attache l'autorisation
# « Enregistrement de l'écran ». Les changer révoque l'autorisation.

set -euo pipefail

BUNDLE_ID="com.opahventures.bran"
IDENTITY="bran-dev"
APP_NAME="bran"
CONFIG="${1:-debug}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/Applications/$APP_NAME.app"

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
rm -rf "$DEST"
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

    <!-- Agent en barre de menus : ni Dock, ni fenêtre au lancement. -->
    <key>LSUIElement</key>               <true/>

    <!-- Textes affichés par macOS dans la fenêtre d'autorisation. Ils doivent
         dire à quoi sert la permission, pas la réclamer. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>bran enregistre votre voix pendant les réunions, et pendant la dictée pour la transcrire sur votre Mac.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>bran lit l'événement en cours pour donner son titre et ses participants à l'enregistrement.</string>

    <!-- La dictée lit le raccourci global et colle le texte : les deux passent
         par l'Accessibilité. macOS ne montre pas ce texte dans sa fenêtre de
         permission, mais il apparaît dans certains outils d'audit — et il dit
         franchement ce que fait l'application. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>bran colle le texte dicté dans l'application où se trouve votre curseur.</string>
</dict>
</plist>
PLIST

echo "→ signature ($IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$DEST"

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
