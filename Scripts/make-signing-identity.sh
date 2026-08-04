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
# Idempotent : ne fait rien si l'identité existe déjà.

set -euo pipefail

NAME="bran-dev"
DAYS=3650
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
