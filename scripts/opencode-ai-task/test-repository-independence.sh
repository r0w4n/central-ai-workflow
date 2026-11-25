#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tmp="$(mktemp -d /tmp/repository-independence.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export AUTOMATION_SHA=1111111111111111111111111111111111111111
export COMPLEXITY=medium
export MODEL=opencode-go/glm-5.3-flash

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

exercise_repo() {
  local name="$1" path="$2"
  local repo="$tmp/$name" artifact="$tmp/$name-artifact" work="$tmp/$name-work"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  mkdir -p "$repo/$(dirname "$path")"
  printf 'base\n' >"$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -qb ai/issue-7
  printf 'feature\n' >>"$repo/$path"
  git -C "$repo" add -A
  git -C "$repo" commit -qm feature
  (
    cd "$repo"
    BRANCH=ai/issue-7 BASE_SHA="$base" ARTIFACT_DIR="$artifact" bash "$here/export-changes.sh" >/dev/null
    git checkout -q "$base"
  )
  ARTIFACT_DIR="$artifact" TRUSTED_REPO="$repo" BASE_SHA="$base" \
    BRANCH=ai/issue-7 ISSUE_NUMBER=7 WORK_DIR="$work" \
    bash "$here/validate-changes.sh" >/dev/null
}

if exercise_repo frontend src/components/widget.ts; then ok "frontend-style repository validates"; else ko "frontend-style repository validates"; fi
if exercise_repo backend service/internal/worker.go; then ok "backend-style repository validates"; else ko "backend-style repository validates"; fi

workflow="$root/.github/workflows/opencode-ai-task.yml"
if ! grep -q 'Rudiment repository' "$workflow" && grep -q 'working-directory: \${{ github.workspace }}' "$workflow"; then
  ok "workflow is repository-independent and pins the agent to the workspace checkout"
else
  ko "workflow is repository-independent and pins the agent to the workspace checkout"
fi
if grep -q 'repository: \${{ job.workflow_repository }}' "$workflow" && grep -q 'path: automation' "$workflow"; then
  ok "central automation uses a separate trusted checkout"
else
  ko "central automation uses a separate trusted checkout"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
