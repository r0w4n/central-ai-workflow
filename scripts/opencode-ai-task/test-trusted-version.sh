#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify="$here/verify-trusted-checkout.sh"
tmp="$(mktemp -d /tmp/trusted-version.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

git init -q "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.com
git -C "$tmp/repo" config user.name test
printf 'trusted\n' >"$tmp/repo/script.sh"
git -C "$tmp/repo" add script.sh
git -C "$tmp/repo" commit -qm base
sha="$(git -C "$tmp/repo" rev-parse HEAD)"

pass=0
fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }

AUTOMATION_REPO="$tmp/repo" AUTOMATION_SHA="$sha" \
  WORKFLOW_REF="r0w4n/central-ai-workflow/.github/workflows/opencode-ai-task.yml@$sha" \
  bash "$verify" >/dev/null
check "exact workflow and script SHA is accepted" "true"

bad=2222222222222222222222222222222222222222
check "central script version drift is rejected" \
  "! AUTOMATION_REPO='$tmp/repo' AUTOMATION_SHA='$bad' WORKFLOW_REF='repo/workflow.yml@$bad' bash '$verify' >/dev/null 2>&1"
check "mutable workflow references are rejected" \
  "! AUTOMATION_REPO='$tmp/repo' AUTOMATION_SHA='$sha' WORKFLOW_REF='repo/workflow.yml@refs/heads/main' bash '$verify' >/dev/null 2>&1"
check "short SHAs are rejected" \
  "! AUTOMATION_REPO='$tmp/repo' AUTOMATION_SHA='${sha:0:12}' WORKFLOW_REF='repo/workflow.yml@${sha:0:12}' bash '$verify' >/dev/null 2>&1"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
