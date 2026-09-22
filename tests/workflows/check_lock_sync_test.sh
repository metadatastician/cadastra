#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Unit and contract tests for scripts/check-lock-sync.sh and its workflow gate.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-lock-sync.sh"
GATE="$REPO_ROOT/.github/workflows/lock-sync-gate.yml"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
TOTAL=0
FIXTURE=""
OUTPUT=""
STATUS=0

new_fixture() {
    FIXTURE="$TMP_ROOT/case-$TOTAL"
    mkdir -p "$FIXTURE"
}

run_checker() {
    STATUS=0
    OUTPUT=$("$CHECKER" "$FIXTURE" 2>&1) || STATUS=$?
}

expect_status() {
    local expected="$1"
    if [ "$STATUS" -ne "$expected" ]; then
        printf 'expected exit status %s, got %s\noutput:\n%s\n' "$expected" "$STATUS" "$OUTPUT" >&2
        return 1
    fi
}

expect_output() {
    local expected="$1"
    if [[ "$OUTPUT" != *"$expected"* ]]; then
        printf 'expected output to contain: %s\nactual output:\n%s\n' "$expected" "$OUTPUT" >&2
        return 1
    fi
}

run_test() {
    local name="$1"
    local test_function="$2"

    TOTAL=$((TOTAL + 1))
    new_fixture
    if "$test_function"; then
        printf 'PASS: %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n' "$name" >&2
        FAIL=$((FAIL + 1))
    fi
}

test_accepts_synchronized_action_with_subpath() {
    cat > "$FIXTURE/build.yaml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: "Example/Tool/sub/action@v1" # subpaths normalize to owner/repo
      - uses: ./local-action
      - uses: docker://alpine:3.22
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yaml':
        - 'example/tool@v1'
dependencies:
    'example/tool@v1':
        ref: 'v1'
EOF

    run_checker
    expect_status 0 && expect_output "actions.lock is in sync and transitively closed"
}

test_detects_unlocked_job_level_workflow() {
    cat > "$FIXTURE/reuse.yml" <<'EOF'
name: Reuse
on: push
jobs:
  delegated:
    uses: example/reusable/.github/workflows/build.yml@v2
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/reuse.yml': []
dependencies:
EOF

    run_checker
    expect_status 1 \
        && expect_output "refs missing from the lockfile: example/reusable@v2"
}

test_reports_workflow_not_onboarded() {
    cat > "$FIXTURE/new.yml" <<'EOF'
name: New
on: push
jobs:
  test:
    steps:
      - uses: example/action@v1
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
dependencies:
EOF

    run_checker
    expect_status 1 \
        && expect_output "not onboarded: no lockfile entry for this path" \
        && expect_output "unlocked refs: example/action@v1"
}

test_detects_stale_ref_for_existing_workflow() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - run: echo done
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml':
        - 'example/unused@v1'
dependencies:
    'example/unused@v1':
        ref: 'v1'
EOF

    run_checker
    expect_status 1 \
        && expect_output "stale lockfile entries, no uses: references them: example/unused@v1"
}

test_detects_lock_entry_for_deleted_workflow() {
    cat > "$FIXTURE/current.yml" <<'EOF'
name: Current
on: push
jobs:
  build:
    steps:
      - run: echo done
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/current.yml': []
    '.github/workflows/deleted.yml': []
dependencies:
EOF

    run_checker
    expect_status 1 \
        && expect_output "FAIL .github/workflows/deleted.yml" \
        && expect_output "lockfile entry for a workflow file that does not exist"
}

test_detects_direct_dangling_dependency() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: example/action@v1
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml':
        - 'example/action@v1'
dependencies:
EOF

    run_checker
    expect_status 1 \
        && expect_output "FAIL actions.lock: DANGLING EDGES" \
        && expect_output "example/action@v1" \
        && expect_output "named by: .github/workflows/build.yml"
}

test_detects_nested_dangling_dependency() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: example/composite@v1
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml':
        - 'example/composite@v1'
dependencies:
    'example/composite@v1':
        ref: 'v1'
        uses:
            - 'example/leaf@v2'
EOF

    run_checker
    expect_status 1 \
        && expect_output "example/leaf@v2" \
        && expect_output "named by: dependencies:example/composite@v1"
}

test_accepts_transitively_closed_dependencies() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: example/composite@v1
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml':
        - 'example/composite@v1'
dependencies:
    'example/composite@v1':
        ref: 'v1'
        uses:
            - 'example/leaf@v2'
    'example/leaf@v2':
        ref: 'v2'
EOF

    run_checker
    expect_status 0 && expect_output "0 dangling edges"
}

test_rejects_dollar_local_action_rewrite() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: $/local-action
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml': []
dependencies:
EOF

    run_checker
    expect_status 1 \
        && expect_output "invalid local-action rewrite (uses: \$/...): \$/local-action"
}

test_fails_without_lockfile() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - run: echo done
EOF

    run_checker
    expect_status 1 && expect_output "FATAL: no lockfile at $FIXTURE/actions.lock"
}

test_fails_without_workflows() {
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
dependencies:
EOF

    run_checker
    expect_status 1 && expect_output "FATAL: no workflow files under $FIXTURE"
}

test_fails_without_gnu_awk() {
    mkdir -p "$FIXTURE/empty-path"
    STATUS=0
    OUTPUT=$(PATH="$FIXTURE/empty-path" /bin/bash "$CHECKER" "$FIXTURE" 2>&1) || STATUS=$?

    expect_status 1 && expect_output "FATAL: no awk supporting 3-argument match()"
}

test_treats_owner_and_repo_case_insensitively() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: Example/Action@v1
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml':
        - 'example/action@v1'
dependencies:
    'EXAMPLE/ACTION@v1':
        ref: 'v1'
EOF

    run_checker
    expect_status 0
}

test_treats_ref_case_sensitively() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - uses: example/action@Release
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml':
        - 'example/action@release'
dependencies:
    'example/action@release':
        ref: 'release'
EOF

    run_checker
    expect_status 1 \
        && expect_output "refs missing from the lockfile: example/action@Release" \
        && expect_output "stale lockfile entries, no uses: references them: example/action@release"
}

test_reports_unreferenced_dependency_as_nonfatal() {
    cat > "$FIXTURE/build.yml" <<'EOF'
name: Build
on: push
jobs:
  build:
    steps:
      - run: echo done
EOF
    cat > "$FIXTURE/actions.lock" <<'EOF'
version: 1
workflows:
    '.github/workflows/build.yml': []
dependencies:
    'example/unreferenced@v1':
        ref: 'v1'
EOF

    run_checker
    expect_status 0 \
        && expect_output "1 dependencies: record(s) are unreferenced - harmless, but prunable"
}

test_gate_remains_self_protecting() {
    local matching_uses matching_paths

    matching_uses=$(grep -Ec '^[[:space:]]*(-[[:space:]]*)?uses:' "$GATE" || true)
    matching_paths=$(grep -Ec '^[[:space:]]*paths:' "$GATE" || true)
    if [ "$matching_uses" -ne 0 ] || [ "$matching_paths" -ne 0 ]; then
        printf 'gate must contain neither uses: nor paths: keys\n' >&2
        return 1
    fi
    grep -Fq 'test -x scripts/check-lock-sync.sh' "$GATE" \
        && grep -Fq './scripts/check-lock-sync.sh' "$GATE"
}

test_repository_lock_is_synchronized() {
    FIXTURE="$REPO_ROOT/.github/workflows"
    run_checker
    expect_status 0 && expect_output "0 dangling edges"
}

run_test "accepts synchronized refs, subpaths, quotes, and local actions" test_accepts_synchronized_action_with_subpath
run_test "detects unlocked job-level reusable workflows" test_detects_unlocked_job_level_workflow
run_test "distinguishes an unonboarded workflow" test_reports_workflow_not_onboarded
run_test "detects stale refs for an existing workflow" test_detects_stale_ref_for_existing_workflow
run_test "detects lock entries for deleted workflows" test_detects_lock_entry_for_deleted_workflow
run_test "detects direct dangling dependencies" test_detects_direct_dangling_dependency
run_test "detects nested dangling dependencies" test_detects_nested_dangling_dependency
run_test "accepts transitively closed dependency graphs" test_accepts_transitively_closed_dependencies
run_test "rejects corrupted dollar-prefixed local actions" test_rejects_dollar_local_action_rewrite
run_test "fails closed when the lockfile is absent" test_fails_without_lockfile
run_test "fails closed when workflows are absent" test_fails_without_workflows
run_test "fails closed when GNU awk is unavailable" test_fails_without_gnu_awk
run_test "folds owner and repository name case" test_treats_owner_and_repo_case_insensitively
run_test "preserves ref case sensitivity" test_treats_ref_case_sensitively
run_test "allows but reports unreferenced dependency records" test_reports_unreferenced_dependency_as_nonfatal
run_test "keeps the lock-sync workflow self-protecting" test_gate_remains_self_protecting
run_test "validates the pull request's regenerated lockfile" test_repository_lock_is_synchronized

printf '\nResults: PASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$TOTAL"
exit "$FAIL"
