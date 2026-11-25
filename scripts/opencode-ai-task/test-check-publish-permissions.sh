#!/usr/bin/env bash
#
# Behavioural tests for scripts/opencode-ai-task/check-publish-permissions.sh.
#
# Uses a stubbed gh command to simulate the repository Actions-permissions API:
# read-only token settings, disabled Actions-created pull requests, allowed
# settings, and an unverifiable API. No network access or credentials.
# Usage: bash scripts/opencode-ai-task/test-check-publish-permissions.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/check-publish-permissions.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp="$(mktemp -d /tmp/opencode-publish-perms.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

run_check() { # $1 = expected rc (0 | 1)
  local expected="$1" out rc
  out="$(PATH="$tmp/bin:$PATH" bash "$check" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    ok "$scenario"
    OUT_LAST="$out"
  else
    ko "$scenario (expected rc=$expected, got rc=$rc): $out"
    OUT_LAST=""
  fi
}

make_gh() { # $1 = JSON response body, or empty for a failing gh
  mkdir -p "$tmp/bin"
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1" >"$tmp/response.json"
    printf '#!/bin/sh\ncat "%s"\n' "$tmp/response.json" >"$tmp/bin/gh"
  else
    printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/gh"
  fi
  chmod +x "$tmp/bin/gh"
}

scenario="pass: read/write token and Actions-created pull requests allowed"
make_gh '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}'
REPOSITORY=owner/repo run_check 0
if grep -q 'pull requests are allowed' <<<"${OUT_LAST:-}"; then
  ok "$scenario (confirmation notice)"
else
  ko "$scenario (missing confirmation notice)"
fi

scenario="fail: default workflow permissions are read-only"
make_gh '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}'
REPOSITORY=owner/repo run_check 1
if grep -q 'Read and write permissions' <<<"${OUT_LAST:-}"; then
  ok "$scenario (remediation)"
else
  ko "$scenario (missing remediation)"
fi

scenario="fail: Actions-created pull requests are disabled"
make_gh '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":false}'
REPOSITORY=owner/repo run_check 1
if grep -q 'cannot be enabled from workflow YAML' <<<"${OUT_LAST:-}"; then
  ok "$scenario (remediation)"
else
  ko "$scenario (missing remediation)"
fi

scenario="warn and continue: the API cannot verify the settings"
make_gh ""
REPOSITORY=owner/repo run_check 0

scenario="warn and continue: response lacks the permission fields"
make_gh '{}'
REPOSITORY=owner/repo run_check 0

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
