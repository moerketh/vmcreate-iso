#!/usr/bin/env bash

# BATS test helper for vmcreate-iso project
# Provides common setup, teardown, and utility functions

# Set project root to repository root
export PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME:-..}/.." && pwd)"

# Setup function runs before each test
setup() {
    # Common test setup
    export TEST_TEMP_DIR=$(mktemp -d)
    cd "$PROJECT_ROOT"
}

# Teardown function runs after each test
teardown() {
    # Common test cleanup
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Don't auto-load functions.sh in test helper to avoid sourcing conflicts
# Individual test files can source functions.sh if needed

# Common utility functions for testing
debug_output() {
    echo "--- DEBUG OUTPUT ---" >&2
    echo "$1" >&2
    echo "--- END DEBUG ---" >&2
}

assert_file_exists() {
    [[ -f "$1" ]] || {
        echo "File does not exist: $1" >&2
        return 1
    }
}

assert_directory_exists() {
    [[ -d "$1" ]] || {
        echo "Directory does not exist: $1" >&2
        return 1
    }
}
