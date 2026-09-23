#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/dogfood-gate.yml"
LOCK="$REPO_ROOT/.github/workflows/actions.lock"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

if ! command -v yq >/dev/null 2>&1; then
    printf 'yq is required to inspect the workflow and lockfile\n' >&2
    exit 1
fi

SCORECARD="$(yq -r '.jobs."dogfood-summary".steps[] | select(.name == "Generate dogfooding scorecard") | .run' "$WORKFLOW")" || exit 1
if [ -z "$SCORECARD" ] || [ "$SCORECARD" = null ]; then
    printf 'Dogfooding scorecard step is missing\n' >&2
    exit 1
fi

TOTAL=0
PASS=0
FAIL=0
FIXTURE=""
SUMMARY=""

fail() {
    printf '%s\n' "$*" >&2
    return 1
}

assert_summary_contains() {
    grep -Fq -- "$1" "$SUMMARY" || fail "Expected scorecard to contain: $1"
}

assert_summary_excludes() {
    if grep -Fqi -- "$1" "$SUMMARY"; then
        fail "Unexpected scorecard content: $1"
    fi
}

run_scorecard() {
    : > "$SUMMARY" || return 1
    (cd "$FIXTURE" && GITHUB_STEP_SUMMARY="$SUMMARY" bash -c "$SCORECARD")
}

run_test() {
    local name="$1"
    local test_function="$2"

    TOTAL=$((TOTAL + 1))
    FIXTURE="$TMP_ROOT/case-$TOTAL"
    SUMMARY="$TMP_ROOT/summary-$TOTAL.md"
    mkdir -p "$FIXTURE"
    if "$test_function"; then
        printf 'PASS: %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n' "$name" >&2
        FAIL=$((FAIL + 1))
    fi
}

test_only_active_jobs_remain() {
    local actual expected

    actual="$(yq -r '.jobs | keys | .[]' "$WORKFLOW" | LC_ALL=C sort)" || return 1
    expected="$(printf '%s\n' k9-validate empty-lint groove-check eclexiaiser-validate dogfood-summary | LC_ALL=C sort)"
    [ "$actual" = "$expected" ] || fail "Unexpected workflow jobs: $actual"
}

test_summary_needs_only_active_jobs() {
    local actual expected

    actual="$(yq -r '.jobs."dogfood-summary".needs[]' "$WORKFLOW" | LC_ALL=C sort)" || return 1
    expected="$(printf '%s\n' k9-validate empty-lint groove-check eclexiaiser-validate | LC_ALL=C sort)"
    [ "$actual" = "$expected" ] || return 1
    [ "$(yq -r '.jobs."dogfood-summary".if' "$WORKFLOW")" = 'always()' ] || fail 'Summary must run even when a validation job fails'
}

test_lock_matches_retained_actions() {
    local action path owner repository reference actual locked

    if grep -Fqi 'hyperpolymath/a2ml-ecosystem' "$LOCK"; then
        fail 'Retired action remains in the lockfile'
        return 1
    fi
    yq -e '.workflows | has(".github/workflows/dogfood-gate.yml")' "$LOCK" >/dev/null || return 1

    actual="$(while IFS= read -r action; do
        path="${action%@*}"
        owner="${path%%/*}"
        repository="${path#*/}"
        repository="${repository%%/*}"
        reference="${action##*@}"
        printf '%s/%s@%s\n' "$owner" "$repository" "$reference"
    done < <(yq -r '.jobs.*.steps[] | select(has("uses")) | .uses' "$WORKFLOW") | LC_ALL=C sort -u)" || return 1
    locked="$(yq -r '.workflows.".github/workflows/dogfood-gate.yml"[]' "$LOCK" | LC_ALL=C sort -u)" || return 1

    if [ "$actual" != "$locked" ]; then
        fail "Workflow uses do not match its lockfile entry: $actual != $locked"
        return 1
    fi
    [[ "$locked" == *'actions/checkout@'* && "$locked" == *'hyperpolymath/k9-ecosystem@main'* ]] \
        || fail 'Required checkout and K9 actions must remain locked'
}

test_empty_repository_has_five_rows_and_zero_score() {
    run_scorecard || return 1
    assert_summary_contains '**Score: 0/5**' \
        && [ "$(grep -Ec '^\| (K9 contracts|\.editorconfig|Groove endpoint|VeriSimDB integration|eclexiaiser) \|' "$SUMMARY")" -eq 5 ] \
        && assert_summary_contains '| K9 contracts | :x: |' \
        && assert_summary_contains '| .editorconfig | :x: |' \
        && assert_summary_contains '| Groove endpoint | :ballot_box_with_check: |' \
        && assert_summary_excludes 'A2ML'
}

test_a2ml_presence_does_not_change_scorecard() {
    local baseline

    run_scorecard || return 1
    baseline="$(cat "$SUMMARY")"
    touch "$FIXTURE/0-AI-MANIFEST.a2ml" || return 1
    run_scorecard || return 1
    [ "$(cat "$SUMMARY")" = "$baseline" ] \
        && assert_summary_contains '**Score: 0/5**' \
        && assert_summary_excludes 'A2ML'
}

test_remaining_five_signals_score_independently() {
    mkdir -p "$FIXTURE/.well-known/groove" || return 1
    touch "$FIXTURE/contract.k9" "$FIXTURE/.editorconfig" \
        "$FIXTURE/.well-known/groove/manifest.json" "$FIXTURE/eclexiaiser.toml" || return 1
    printf 'integration: verisimdb\n' > "$FIXTURE/service.yml" || return 1

    run_scorecard || return 1
    assert_summary_contains '**Score: 5/5**' \
        && assert_summary_contains '| K9 contracts | :white_check_mark: |' \
        && assert_summary_contains '| .editorconfig | :white_check_mark: |' \
        && assert_summary_contains '| Groove endpoint | :white_check_mark: |' \
        && assert_summary_contains '| VeriSimDB integration | :white_check_mark: |' \
        && assert_summary_contains '| eclexiaiser | :white_check_mark: |' \
        && assert_summary_excludes 'A2ML'
}

test_partial_repository_counts_only_present_signals() {
    touch "$FIXTURE/contract.k9.ncl" "$FIXTURE/.editorconfig" || return 1
    run_scorecard || return 1
    assert_summary_contains '**Score: 2/5**' \
        && assert_summary_contains '| VeriSimDB integration | :ballot_box_with_check: |' \
        && assert_summary_contains '| eclexiaiser | :ballot_box_with_check: |'
}

run_test 'retired job is removed without changing the other jobs' test_only_active_jobs_remain
run_test 'summary depends only on the four active checks' test_summary_needs_only_active_jobs
run_test 'lockfile matches remaining workflow action references' test_lock_matches_retained_actions
run_test 'empty repository has five checks and no A2ML row' test_empty_repository_has_five_rows_and_zero_score
run_test 'A2ML manifest cannot affect the scorecard' test_a2ml_presence_does_not_change_scorecard
run_test 'remaining five signals contribute to the score' test_remaining_five_signals_score_independently
run_test 'partial compliance counts only present signals' test_partial_repository_counts_only_present_signals

printf '\nResults: PASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$TOTAL"
exit "$FAIL"
