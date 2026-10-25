#!/bin/bash
set -euo pipefail

# Verify a signed vmcreate-iso release — the same checks VMCreate runs:
#
#   release/verify.sh <manifest.json> <manifest.json.sig> <iso>
#
# 1. the signature over the exact manifest bytes is valid for the trusted
#    key the manifest names (keys/<key_id>.pub.pem);
# 2. only then are the manifest's fields read, and the ISO's size and
#    SHA-256 must match them.
#
# Needs only openssl and coreutils. KEYS_DIR overrides the trusted key
# directory (tests only).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KEYS_DIR=${KEYS_DIR:-"$SCRIPT_DIR/../keys"}

die() { echo "FAIL: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: $0 <manifest.json> <manifest.json.sig> <iso>"
MANIFEST=$1 SIG=$2 ISO=$3
for f in "$MANIFEST" "$SIG" "$ISO"; do [ -f "$f" ] || die "not found: $f"; done

# Read one "key": value line of the fixed manifest layout.
field() { sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$MANIFEST"; }

# The key id is read before the signature is checked, so it is only used
# to pick a file — strictly 16 hex, never a path.
KEY_ID=$(field key_id)
echo "$KEY_ID" | grep -Eq '^[0-9a-f]{16}$' || die "manifest key_id is malformed"
PUBKEY="$KEYS_DIR/$KEY_ID.pub.pem"
[ -f "$PUBKEY" ] || die "manifest is signed by untrusted key $KEY_ID"

openssl dgst -sha256 -verify "$PUBKEY" -signature "$SIG" "$MANIFEST" >/dev/null 2>&1 \
    || die "signature does not verify with key $KEY_ID"

# Signature valid: the manifest is ours, byte for byte.
[ "$(field schema)" = "1" ] || die "unsupported manifest schema '$(field schema)'"
[ "$(field name)" = "vmcreate-iso" ] || die "manifest is not for vmcreate-iso"

WANT_SIZE=$(field iso_size)
WANT_SHA=$(field iso_sha256)
HAVE_SIZE=$(stat -c %s "$ISO")
[ "$HAVE_SIZE" = "$WANT_SIZE" ] || die "ISO size $HAVE_SIZE != signed size $WANT_SIZE"
HAVE_SHA=$(sha256sum "$ISO" | cut -d' ' -f1)
[ "$HAVE_SHA" = "$WANT_SHA" ] || die "ISO sha256 $HAVE_SHA != signed sha256 $WANT_SHA"

echo "OK: $(basename "$ISO") is vmcreate-iso $(field version) ($(field tag), commit $(field commit)), signed by key $KEY_ID"
