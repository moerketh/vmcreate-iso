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

@test "only the build job escalates, to contents:write alone" {
    # job-level blocks: the top-level default plus exactly one job override
    [ "$(grep -c '^    permissions:$' "$WORKFLOW")" -eq 1 ]
    grep -q '^      contents: write$' "$WORKFLOW"
    # actions:write (artifact cleanup) is step-scoped, never job-wide
    ! grep -q '^      actions: write$' "$WORKFLOW"
    grep -q '^          actions: write$' "$WORKFLOW"
}
