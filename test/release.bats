#!/usr/bin/env bats
# Release signing round trip with throwaway keys: the manifest VMCreate
# trusts the ISO by must verify when untouched and fail on any change to
# the manifest, the signature or the ISO — and only trusted keys sign.

load 'test_helper'

MAKE="$PROJECT_ROOT/release/make-manifest.sh"
VERIFY="$PROJECT_ROOT/release/verify.sh"
COMMIT=0123456789abcdef0123456789abcdef01234567

# A fresh P-256 key, its public half in a test-only trusted keys dir.
new_key() {  # <name> <trusted: yes|no>
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out "$TEST_TEMP_DIR/$1.pem" 2>/dev/null
    if [ "$2" = yes ]; then
        local id
        id=$(openssl pkey -in "$TEST_TEMP_DIR/$1.pem" -pubout -outform DER | sha256sum | cut -c1-16)
        openssl pkey -in "$TEST_TEMP_DIR/$1.pem" -pubout -out "$KEYS_DIR/$id.pub.pem"
    fi
}

# Flip one byte (offset $2) of file $1.
flip_byte() {
    local b
    b=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
    printf "$(printf '\\%03o' $(( (b + 1) % 256 )))" \
        | dd of="$1" bs=1 seek="$2" count=1 conv=notrunc 2>/dev/null
}

sign() {  # [version] [tag]
    ISO_SIGNING_KEY=$(cat "$TEST_TEMP_DIR/signer.pem") \
        "$MAKE" "$ISO" "${1:-2.1.0}" "${2:-v2.1.0}" "$COMMIT"
}

setup() {
    export TEST_TEMP_DIR=$(mktemp -d)
    export KEYS_DIR="$TEST_TEMP_DIR/keys"
    mkdir -p "$KEYS_DIR" "$TEST_TEMP_DIR/out"
    export TMPDIR="$TEST_TEMP_DIR/tmp"
    mkdir -p "$TMPDIR"
    ISO="$TEST_TEMP_DIR/out/vmcreate-2.1.0.iso"
    head -c 300000 /dev/urandom > "$ISO"
    MANIFEST="$TEST_TEMP_DIR/out/vmcreate-2.1.0.manifest.json"
    SIG="$MANIFEST.sig"
    new_key signer yes
    cd "$PROJECT_ROOT"
}

@test "signed release verifies" {
    run sign
    [ "$status" -eq 0 ]
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -eq 0 ]
    [[ "$output" == OK:* ]]
}

@test "manifest records the signed facts" {
    sign
    grep -q '^  "version": "2.1.0",$' "$MANIFEST"
    grep -q '^  "tag": "v2.1.0",$' "$MANIFEST"
    grep -q "^  \"commit\": \"$COMMIT\",\$" "$MANIFEST"
    grep -q "^  \"iso_size\": $(stat -c %s "$ISO"),\$" "$MANIFEST"
    grep -q "^  \"iso_sha256\": \"$(sha256sum "$ISO" | cut -d' ' -f1)\",\$" "$MANIFEST"
}

@test "private key never stays on disk" {
    sign
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "one changed manifest byte fails verification" {
    sign
    # inside the version value: still well-formed, no longer what was signed
    sed -i 's/"version": "2.1.0"/"version": "2.1.1"/' "$MANIFEST"
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"signature does not verify"* ]]
}

@test "one changed signature byte fails verification" {
    sign
    flip_byte "$SIG" 20
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
}

@test "one changed ISO byte fails verification" {
    sign
    flip_byte "$ISO" 150000
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256"* ]]
}

@test "truncated ISO fails verification" {
    sign
    truncate -s -1 "$ISO"
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"size"* ]]
}

@test "manifest from an untrusted key is rejected" {
    sign
    rm "$KEYS_DIR"/*.pub.pem
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"untrusted key"* ]]
}

@test "signature by another trusted key under a forged key_id is rejected" {
    sign
    new_key other yes
    openssl dgst -sha256 -sign "$TEST_TEMP_DIR/other.pem" -out "$SIG" "$MANIFEST"
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
}

@test "key_id cannot point outside the keys dir" {
    sign
    sed -i 's/"key_id": "[0-9a-f]*"/"key_id": "..\/..\/evil"/' "$MANIFEST"
    run "$VERIFY" "$MANIFEST" "$SIG" "$ISO"
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed"* ]]
}

@test "signing with a key that is not in keys/ is refused" {
    new_key rogue no
    run env ISO_SIGNING_KEY="$(cat "$TEST_TEMP_DIR/rogue.pem")" \
        "$MAKE" "$ISO" 2.1.0 v2.1.0 "$COMMIT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a trusted key"* ]]
    [ ! -e "$MANIFEST" ]
}

@test "tag must match version" {
    run sign 2.1.0 v2.1.1
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match"* ]]
}

@test "missing or garbage key is refused" {
    run env -u ISO_SIGNING_KEY "$MAKE" "$ISO" 2.1.0 v2.1.0 "$COMMIT"
    [ "$status" -ne 0 ]
    run env ISO_SIGNING_KEY="not a key" "$MAKE" "$ISO" 2.1.0 v2.1.0 "$COMMIT"
    [ "$status" -ne 0 ]
}

@test "committed trusted keys are P-256 and named by their key_id" {
    shopt -s nullglob
    keys=("$PROJECT_ROOT"/keys/*.pub.pem)
    [ "${#keys[@]}" -ge 1 ] || skip "keys/ not populated yet"
    for k in "${keys[@]}"; do
        openssl pkey -pubin -in "$k" -noout -text | grep -q 'NIST CURVE: P-256'
        id=$(openssl pkey -pubin -in "$k" -outform DER | sha256sum | cut -c1-16)
        [ "$(basename "$k")" = "$id.pub.pem" ]
    done
}
