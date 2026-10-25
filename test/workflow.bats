#!/usr/bin/env bats
# Assertions on the CI workflow's supply-chain posture. The build job is
# the release authority for the ISO VMCreate auto-downloads, so every
# action it runs must be bound to an immutable commit SHA (floating tags
# resolve to whatever upstream points them at, with the job's write
# token), and its token must stay scoped to what publishing needs.

load 'test_helper'

WORKFLOW="$PROJECT_ROOT/.github/workflows/main.yml"

@test "every workflow action is pinned to a commit SHA" {
    pinned=0
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if ! echo "$ref" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$'; then
            echo "unpinned action ref: $ref" >&2
            return 1
        fi
        pinned=$((pinned + 1))
    done < <(grep -oE 'uses: [^ ]+' "$WORKFLOW" | sed 's/uses: //' | sed 's/ #.*//' | sort -u)
    [ "$pinned" -ge 4 ]
}

@test "workflow default permissions are read-only" {
    grep -q '^permissions:$' "$WORKFLOW"
    grep -q '^  contents: read$' "$WORKFLOW"
}

# Print one job's block: from "  <job>:" up to the next top-level job key.
job_block() {
    awk -v job="  $1:" '
        $0 == job { inside = 1; print; next }
        inside && /^  [A-Za-z0-9_-]+:$/ { exit }
        inside { print }
    ' "$WORKFLOW"
}

@test "no step-level permissions (GitHub only honors workflow/job level)" {
    # steps sit at 6 spaces ("      - name:"), their keys at 8
    ! grep -Eq '^ {8,}permissions:' "$WORKFLOW"
}

@test "build job holds no write permission" {
    block=$(job_block build)
    [ -n "$block" ]
    ! echo "$block" | grep -q 'permissions:'
    ! echo "$block" | grep -q ': write'
}

@test "only sign-release gets contents:write" {
    [ "$(grep -c '^      contents: write$' "$WORKFLOW")" -eq 1 ]
    job_block sign-release | grep -q '^      contents: write$'
}

@test "sign-release runs only for tags, behind the release environment" {
    block=$(job_block sign-release)
    echo "$block" | grep -q "^    if: github.ref_type == 'tag'$"
    echo "$block" | grep -q '^    environment: release$'
    echo "$block" | grep -q 'GITHUB_REF_NAME" != "v$VERSION"'
}

@test "sign-release checks out only release/ and keys/, without credentials" {
    block=$(job_block sign-release)
    [ "$(echo "$block" | grep -c 'actions/checkout')" -eq 1 ]
    echo "$block" | grep -q '^          sparse-checkout-cone-mode: false$'
    echo "$block" | grep -q '^          persist-credentials: false$'
    # exactly the two patterns, nothing else
    patterns=$(echo "$block" | awk '/sparse-checkout: \|/ {f=1; next} f && /^            / {print $1; next} f {exit}')
    [ "$patterns" = "$(printf '/release/\n/keys/')" ]
    ! echo "$block" | grep -Eq 'build\.sh|chroot_setup\.sh'
}

@test "ISO_SIGNING_KEY is only readable by the signing step" {
    [ "$(grep -c 'secrets.ISO_SIGNING_KEY' "$WORKFLOW")" -eq 1 ]
    job_block sign-release | grep -q 'ISO_SIGNING_KEY: ${{ secrets.ISO_SIGNING_KEY }}'
    # no job-wide or workflow-wide exposure
    ! grep -Eq '^ {0,4}[A-Za-z_]+: \$\{\{ secrets\.' "$WORKFLOW"
}

@test "release publishes the signed manifest after verifying it" {
    block=$(job_block sign-release)
    sign_line=$(echo "$block" | grep -n 'release/make-manifest.sh' | cut -d: -f1)
    verify_line=$(echo "$block" | grep -n 'release/verify.sh' | cut -d: -f1)
    publish_line=$(echo "$block" | grep -n 'ncipollo/release-action' | cut -d: -f1)
    [ -n "$sign_line" ] && [ -n "$verify_line" ] && [ -n "$publish_line" ]
    [ "$sign_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$publish_line" ]
    echo "$block" | grep -q 'manifest.json,vmcreate-${{ needs.build.outputs.version }}.manifest.json.sig'
}

@test "cleanup-artifacts is the only actions:write job and runs no repo code" {
    [ "$(grep -c '^      actions: write$' "$WORKFLOW")" -eq 1 ]
    block=$(job_block cleanup-artifacts)
    echo "$block" | grep -q '^      actions: write$'
    echo "$block" | grep -q "^    if: github.ref_type == 'branch'$"
    ! echo "$block" | grep -q 'actions/checkout'
}

@test "tag-run artifacts are named apart from branch artifacts" {
    # cleanup deletes same-name artifacts of other runs; a release ISO
    # waiting for approval must never share that name
    grep -q 'artifact=vmcreate-iso-${VERSION}-release' "$WORKFLOW"
}
