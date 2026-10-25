#!/bin/bash
set -euo pipefail

# Write and sign the release manifest VMCreate trusts the ISO by.
#
#   ISO_SIGNING_KEY=<PEM> release/make-manifest.sh <iso> <version> <tag> <commit>
#
# Produces <iso dir>/vmcreate-<version>.manifest.json and .manifest.json.sig
# (ECDSA P-256 / SHA-256, DER, over the exact manifest bytes), then checks
# the result with release/verify.sh against the trusted keys in keys/.
#
# The manifest layout is fixed — one field per line, written only here —
# so verify.sh (and VMCreate) can read it back without a JSON tool once
# the signature has proven nobody changed a byte of it.
#
# KEYS_DIR overrides the trusted key directory (tests only).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KEYS_DIR=${KEYS_DIR:-"$SCRIPT_DIR/../keys"}

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 4 ] || die "usage: ISO_SIGNING_KEY=<PEM> $0 <iso> <version> <tag> <commit>"
ISO=$1 VERSION=$2 TAG=$3 COMMIT=$4

[ -f "$ISO" ] || die "ISO not found: $ISO"
# Same token rule as build.sh: the values land in file names and JSON.
echo "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}(-[A-Za-z0-9.]+)?$' \
    || die "invalid version: '$VERSION'"
[ "$TAG" = "v$VERSION" ] || die "tag '$TAG' does not match version '$VERSION' (want v$VERSION)"
echo "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "commit must be a full 40-hex SHA: '$COMMIT'"
[ -n "${ISO_SIGNING_KEY:-}" ] || die "ISO_SIGNING_KEY is not set"

# The private key only ever touches disk as a 0600 temp file, removed on
# every exit path.
umask 077
KEY_FILE=$(mktemp)
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s\n' "$ISO_SIGNING_KEY" > "$KEY_FILE"

# key_id: first 16 hex of sha256(DER SubjectPublicKeyInfo) — computable
# the same way in .NET (ExportSubjectPublicKeyInfo + SHA256).
KEY_ID=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | sha256sum | cut -c1-16) \
    || die "ISO_SIGNING_KEY is not a readable private key"
echo "$KEY_ID" | grep -Eq '^[0-9a-f]{16}$' || die "ISO_SIGNING_KEY is not a readable private key"
[ -f "$KEYS_DIR/$KEY_ID.pub.pem" ] \
    || die "signing key $KEY_ID is not a trusted key (no $KEYS_DIR/$KEY_ID.pub.pem)"
openssl pkey -in "$KEY_FILE" -noout -text 2>/dev/null | grep -q 'NIST CURVE: P-256' \
    || die "signing key must be ECDSA P-256"

ISO_DIR=$(cd "$(dirname "$ISO")" && pwd)
ISO_FILE=$(basename "$ISO")
SIZE=$(stat -c %s "$ISO")
SHA256=$(sha256sum "$ISO" | cut -d' ' -f1)
MANIFEST="$ISO_DIR/vmcreate-$VERSION.manifest.json"

cat > "$MANIFEST" <<EOF
{
  "schema": 1,
  "name": "vmcreate-iso",
  "version": "$VERSION",
  "tag": "$TAG",
  "commit": "$COMMIT",
  "iso_file": "$ISO_FILE",
  "iso_size": $SIZE,
  "iso_sha256": "$SHA256",
  "key_id": "$KEY_ID"
}
EOF
chmod 644 "$MANIFEST"

openssl dgst -sha256 -sign "$KEY_FILE" -out "$MANIFEST.sig" "$MANIFEST"
chmod 644 "$MANIFEST.sig"

# Never publish what the trusted public key would not accept.
KEYS_DIR="$KEYS_DIR" bash "$SCRIPT_DIR/verify.sh" "$MANIFEST" "$MANIFEST.sig" "$ISO" >/dev/null \
    || die "self-verification of the signed manifest failed"

echo "Signed $MANIFEST (key $KEY_ID)"
