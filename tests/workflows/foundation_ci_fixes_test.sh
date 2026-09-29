#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Contract tests for the foundation CI security fixes in pull request #54,
# extended by the issue #52 triage: the advanced-config CodeQL workflow was
# retired (default setup conflict) and the shared foundation pin moved to a
# resolvable standards commit.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
MANAGED_HEADER="# This workflow is managed by gh actions-lock."

# Resolvable, immutable shared-foundation pin (hyperpolymath/standards).
FOUNDATION_SHA="e3b9929cdc57149874e2211e6c8934145d245855"
# Revisions that never resolved upstream (fabricated by #54) — must stay gone.
for dead_sha in \
    8f31a5a4ba591d544b65f91f6d78b136e07756f0 \
    cc58c0cb23f73fc2019ce85a56a468e5248a93b3 \
    8750b94ac1bbe8c51ad13fe106669b13478f0b62; do
    DEAD_REFS+=("$dead_sha")
done
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

test_reusable_workflows_use_expected_revisions() {
    local specification file job workflow revision expected actual
    local specifications=(
        "governance.yml|governance|hyperpolymath/standards/.github/workflows/governance-reusable.yml|$FOUNDATION_SHA"
        "hypatia-scan.yml|scan|hyperpolymath/standards/.github/workflows/hypatia-scan-reusable.yml|$FOUNDATION_SHA"
        "scorecard.yml|scorecard|hyperpolymath/standards/.github/workflows/scorecard-reusable.yml|$FOUNDATION_SHA"
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

test_non_resolving_foundation_revisions_are_absent() {
    local dead_sha file

    for dead_sha in "${DEAD_REFS[@]}"; do
        for file in governance.yml hypatia-scan.yml scorecard.yml; do
            if grep -Fq "$dead_sha" "$WORKFLOWS/$file"; then
                fail "Non-resolving revision $dead_sha remains in $file"
                return 1
            fi
        done
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

run_test 'reusable workflows use their expected immutable revisions' test_reusable_workflows_use_expected_revisions
run_test 'the superseded shared foundation revision is absent' test_superseded_foundation_revision_is_absent
run_test 'non-resolving foundation revisions are absent' test_non_resolving_foundation_revisions_are_absent
run_test 'newly managed workflows start with the management header' test_newly_managed_workflows_have_the_header_first
run_test 'managed headers preserve nearby SPDX declarations' test_managed_header_keeps_spdx_near_the_top

printf '\nResults: PASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$TOTAL"
exit "$FAIL"
