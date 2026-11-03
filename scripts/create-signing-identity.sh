#!/bin/zsh
# One time, on the Mac that builds releases: create a stable self-signed
# code-signing identity in the login keychain.
#
# Why: an ad-hoc signature changes with every build, so macOS treats each
# update as a new app and silently drops its Accessibility / Input Monitoring
# grants. Signing every build with the same certificate keeps the app's
# designated requirement, and therefore the user's grants, across updates.
# No Apple developer account is involved; this does not notarize the app.
#
# The first build afterwards may show "codesign wants to use key ..." — enter
# the Mac login password and choose "Always Allow".
set -euo pipefail
name=${1:-"Toss Local Signing"}
keychain=${2:-"$HOME/Library/Keychains/login.keychain-db"}
if /usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/grep -qF "\"$name\""; then
  print "Signing identity already exists: $name"
  exit 0
fi
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/toss-signing.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
pass=$(/usr/bin/uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -passout "pass:$pass" -out "$work/identity.p12"
/usr/bin/security import "$work/identity.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null
print "Created signing identity: $name"
print "scripts/build-release.py will use it from now on."
