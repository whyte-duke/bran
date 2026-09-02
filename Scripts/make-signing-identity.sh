#!/bin/zsh
#
# Crée l'identité de signature `bran-dev` et l'installe dans le trousseau
# « Connexion ».
#
# Pourquoi un script plutôt que l'Assistant de certification : l'autorisation
# « Enregistrement de l'écran » de macOS est attachée à la signature de code.
# Si la signature change, l'autorisation est révoquée. Il faut donc pouvoir
# recréer EXACTEMENT la même identité — ce qu'un formulaire à quinze écrans ne
# garantit pas.
#
# **Et jusqu'ici, ce script ne le garantissait pas non plus.** Il générait une
# clé RSA neuve à chaque exécution. Relancé sur un trousseau vidé, sur un autre
# Mac, ou après une suppression accidentelle, il produisait un certificat
# *différent* portant le même nom — donc une signature différente, donc les
# autorisations perdues en silence, la case restant cochée dans les Réglages
# système. C'est précisément la panne que l'en-tête promettait d'éviter, et le
# « idempotent » ne couvrait que le cas facile : l'identité encore présente.
#
# Une identité ne se « recrée » pas : elle se **conserve**. D'où les deux modes
# ajoutés, qui sont ce que la promesse exigeait depuis le début :
#
#   zsh Scripts/make-signing-identity.sh exporter <fichier.p12>
#   zsh Scripts/make-signing-identity.sh importer <fichier.p12>
#
# Le fichier exporté est la clé privée de signature de bran. Il ne va **pas**
# dans le dépôt (`.gitignore` ignore `*.p12` depuis ce commit), et il vaut
# exactement ce que valent les autorisations qu'il préserve.
#
# Sans argument : crée l'identité si elle manque, ne fait rien sinon.

set -euo pipefail

NAME="bran-dev"
DAYS=3650
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MODE="${1:-creer}"

case "$MODE" in
  exporter)
    DEST="${2:-}"
    if [[ -z "$DEST" ]]; then
      echo "✗ usage : zsh Scripts/make-signing-identity.sh exporter <fichier.p12>"
      exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
      echo "✗ l'identité « $NAME » n'existe pas — rien à exporter."
      exit 1
    fi
    echo "→ export de « $NAME » vers $DEST"
    echo "  macOS va demander votre mot de passe de session, puis un mot de"
    echo "  passe pour protéger le fichier. Notez-le : sans lui, l'import est"
    echo "  impossible et l'identité est perdue quand même."
    security export -k "$KEYCHAIN" -t identities -f pkcs12 -o "$DEST"
    chmod 600 "$DEST"
    echo
    echo "✓ exporté : $DEST"
    echo "  Ce fichier EST la signature de bran. Rangez-le où vous rangez vos"
    echo "  secrets, jamais dans le dépôt. Il préserve les autorisations"
    echo "  d'écran et d'accessibilité à travers un changement de Mac ou une"
    echo "  réinitialisation de trousseau."
    exit 0
    ;;
  importer)
    SRC="${2:-}"
    if [[ -z "$SRC" || ! -f "$SRC" ]]; then
      echo "✗ usage : zsh Scripts/make-signing-identity.sh importer <fichier.p12>"
      exit 1
    fi
    if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
      echo "✗ l'identité « $NAME » existe déjà dans ce trousseau."
      echo "  Importer par-dessus créerait un doublon, et codesign choisirait"
      echo "  l'un des deux sans le dire. Retirez d'abord l'existante depuis"
      echo "  Trousseaux d'accès si vous voulez vraiment la remplacer."
      exit 1
    fi
    echo "→ import de $SRC"
    security import "$SRC" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
    echo "→ déclaration comme racine de confiance"
    security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem"
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    echo
    echo "=== vérification ==="
    security find-identity -v -p codesigning
    exit 0
    ;;
  creer) ;;
  *)
    echo "✗ mode inconnu : « $MODE »"
    echo "  usage : zsh Scripts/make-signing-identity.sh [exporter|importer <fichier.p12>]"
    exit 1
    ;;
esac

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ l'identité « $NAME » existe déjà — rien à faire"
  security find-identity -v -p codesigning
  exit 0
fi

echo "→ génération de la clé et du certificat auto-signé ($DAYS jours)"

cat > "$WORK/openssl.cnf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no

[dn]
CN = bran-dev
O  = OpahVentures

[codesign]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CONF

openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# Les algorithmes PKCS#12 par défaut d'OpenSSL 3 (AES-256, MAC SHA-256) sont
# refusés par Security.framework, qui échoue sur « MAC verification failed ».
# Il faut les algorithmes historiques.
openssl pkcs12 -export \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/$NAME.p12" \
  -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -passout pass:temporaire 2>/dev/null

echo "→ import dans le trousseau Connexion"
# -T /usr/bin/codesign : autorise codesign à utiliser la clé sans redemander
# l'autorisation à chaque signature.
security import "$WORK/$NAME.p12" \
  -k "$KEYCHAIN" \
  -P temporaire \
  -T /usr/bin/codesign \
  -T /usr/bin/security

echo "→ déclaration du certificat comme racine de confiance"
echo "  (macOS va demander votre mot de passe de session)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
echo "=== vérification ==="
security find-identity -v -p codesigning

# **L'avertissement qui manquait, et qui coûte cher à ne pas lire.**
#
# Cette identité vient d'être créée. Si un bran.app signé par une identité
# *précédente* portant le même nom traîne encore, ses autorisations sont déjà
# perdues — la case reste cochée dans les Réglages système, et ScreenCaptureKit
# rend le fond d'écran sans les fenêtres. Voir `ScreenAccess`, qui existe pour
# détecter exactement ça.
echo
echo "⚠ Exportez cette identité maintenant, pendant qu'elle existe :"
echo
echo "    zsh Scripts/make-signing-identity.sh exporter ~/bran-dev.p12"
echo
echo "  Sans ce fichier, un trousseau réinitialisé ou un autre Mac vous fera"
echo "  regénérer une identité DIFFÉRENTE sous le même nom — et macOS révoquera"
echo "  silencieusement l'autorisation « Enregistrement de l'écran », sans"
echo "  décocher la case."
if [[ -d "$HOME/Applications/bran.app" ]]; then
  echo
  echo "⚠ ~/Applications/bran.app existe et a été signé par une identité"
  echo "  antérieure. Reconstruisez-le, puis :"
  echo "    tccutil reset ScreenCapture com.opahventures.bran"
  echo "    tccutil reset Microphone    com.opahventures.bran"
fi
