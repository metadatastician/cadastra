#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Contract tests for the foundation CI security fixes in pull request #54.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
CODEQL="$WORKFLOWS/codeql.yml"
MANAGED_HEADER="# This workflow is managed by gh actions-lock."

CHECKOUT_SHA="3d3c42e5aac5ba805825da76410c181273ba90b1"
CODEQL_SHA="cdf488f595d80d6e07e03d4674febd5ab45fa938"
OLD_FOUNDATION_SHA="bd0df9ead7faf0cdfe0e13e7966d91e28d0101d4"

TOTAL=0
PASS=0
FAIL=0

fail() {
    printf '%s\n' "$*" >&2
    return 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local context="$3"

    if [ "$actual" != "$expected" ]; then
        printf '%s\nexpected: %s\nactual:   %s\n' "$context" "$expected" "$actual" >&2
        return 1
    fi
}

assert_immutable_ref() {
    local action_ref="$1"
    local revision="${action_ref##*@}"

    [[ "$action_ref" == *@* ]] \
        || fail "External action reference has no revision: $action_ref" \
        || return 1
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] \
        || fail "External action reference is not pinned to a full commit SHA: $action_ref"
}

run_test() {
    local name="$1"
    local test_function="$2"

    TOTAL=$((TOTAL + 1))
    if "$test_function"; then
        printf 'PASS: %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n' "$name" >&2
        FAIL=$((FAIL + 1))
    fi
}

test_codeql_action_sequence_is_preserved() {
    local actual expected

    actual="$(yq -r '.jobs.analyze.steps[] | select(has("uses")) | .uses' "$CODEQL")" || return 1
    expected="$(printf '%s\n' \
        "actions/checkout@$CHECKOUT_SHA" \
        "github/codeql-action/init@$CODEQL_SHA" \
        "github/codeql-action/analyze@$CODEQL_SHA")"

    assert_equal "$expected" "$actual" 'CodeQL action sequence or revision changed'
}

test_codeql_actions_are_immutable() {
    local action_ref

    while IFS= read -r action_ref; do
        [ -n "$action_ref" ] || continue
        assert_immutable_ref "$action_ref" || return 1
    done < <(yq -r '.jobs.analyze.steps[] | select(has("uses")) | .uses' "$CODEQL")
}

test_checkout_does_not_persist_credentials() {
    local actual value_type count

    actual="$(yq -r ".jobs.analyze.steps[] | select(.uses == \"actions/checkout@$CHECKOUT_SHA\") | .with.\"persist-credentials\"" "$CODEQL")" \
        || return 1
    value_type="$(yq -r ".jobs.analyze.steps[] | select(.uses == \"actions/checkout@$CHECKOUT_SHA\") | .with.\"persist-credentials\" | tag" "$CODEQL")" \
        || return 1
    count="$(yq -r '[.jobs.analyze.steps[] | select(.with."persist-credentials" != null)] | length' "$CODEQL")" \
        || return 1

    assert_equal 'false' "$actual" 'Checkout must disable persisted credentials' \
        && assert_equal '!!bool' "$value_type" 'persist-credentials must be a YAML boolean, not a string' \
        && assert_equal '1' "$count" 'persist-credentials must be scoped to exactly one step'
}

test_codeql_init_and_analyze_share_a_revision() {
    local init_ref analyze_ref

    init_ref="$(yq -r '.jobs.analyze.steps[] | select(.name == "Initialize CodeQL") | .uses' "$CODEQL")" \
        || return 1
    analyze_ref="$(yq -r '.jobs.analyze.steps[] | select(.name == "Perform CodeQL Analysis") | .uses' "$CODEQL")" \
        || return 1

    assert_equal "github/codeql-action/init@$CODEQL_SHA" "$init_ref" 'Unexpected CodeQL init reference' \
        && assert_equal "github/codeql-action/analyze@$CODEQL_SHA" "$analyze_ref" 'Unexpected CodeQL analyze reference' \
        && assert_equal "${init_ref##*@}" "${analyze_ref##*@}" 'CodeQL init and analyze revisions must stay aligned'
}

test_reusable_workflows_use_expected_revisions() {
    local specification file job workflow revision expected actual
    local specifications=(
        'governance.yml|governance|hyperpolymath/standards/.github/workflows/governance-reusable.yml|8f31a5a4ba591d544b65f91f6d78b136e07756f0'
        'hypatia-scan.yml|scan|hyperpolymath/standards/.github/workflows/hypatia-scan-reusable.yml|cc58c0cb23f73fc2019ce85a56a468e5248a93b3'
        'scorecard.yml|scorecard|hyperpolymath/standards/.github/workflows/scorecard-reusable.yml|8750b94ac1bbe8c51ad13fe106669b13478f0b62'
    )

    for specification in "${specifications[@]}"; do
        IFS='|' read -r file job workflow revision <<< "$specification"
        expected="$workflow@$revision"
        actual="$(yq -r ".jobs.\"$job\".uses" "$WORKFLOWS/$file")" || return 1
        assert_equal "$expected" "$actual" "Unexpected reusable workflow reference in $file" \
            && assert_immutable_ref "$actual" \
            || return 1
    done
}

test_superseded_foundation_revision_is_absent() {
    local file

    for file in governance.yml hypatia-scan.yml scorecard.yml; do
        if grep -Fq "$OLD_FOUNDATION_SHA" "$WORKFLOWS/$file"; then
            fail "Superseded foundation revision remains in $file"
            return 1
        fi
    done
}

test_newly_managed_workflows_have_the_header_first() {
    local file actual

    for file in label-triage.yml labels.yml push-email-notify.yml; do
        IFS= read -r actual < "$WORKFLOWS/$file" || return 1
        assert_equal "$MANAGED_HEADER" "$actual" "Managed-workflow header is not first in $file" \
            || return 1
    done
}

test_managed_header_keeps_spdx_near_the_top() {
    local file

    for file in label-triage.yml labels.yml push-email-notify.yml; do
        if ! head -n 3 "$WORKFLOWS/$file" | grep -Fq '# SPDX-License-Identifier: MPL-2.0'; then
            fail "SPDX header moved out of the first three lines in $file"
            return 1
        fi
    done
}

if ! command -v yq >/dev/null 2>&1; then
    printf 'yq is required to inspect the workflow files\n' >&2
    exit 1
fi

run_test 'CodeQL keeps checkout, initialization, and analysis in order' test_codeql_action_sequence_is_preserved
run_test 'CodeQL external actions use immutable commit revisions' test_codeql_actions_are_immutable
run_test 'checkout disables credential persistence with a boolean' test_checkout_does_not_persist_credentials
run_test 'CodeQL initialization and analysis stay on one revision' test_codeql_init_and_analyze_share_a_revision
run_test 'reusable workflows use their expected immutable revisions' test_reusable_workflows_use_expected_revisions
run_test 'the superseded shared foundation revision is absent' test_superseded_foundation_revision_is_absent
run_test 'newly managed workflows start with the management header' test_newly_managed_workflows_have_the_header_first
run_test 'managed headers preserve nearby SPDX declarations' test_managed_header_keeps_spdx_near_the_top

printf '\nResults: PASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$TOTAL"
exit "$FAIL"
