#!/usr/bin/env bash
# A failed agent's dirty work must survive as a validated patch artifact.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d /tmp/checkpoint-tests.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

git init -q "$tmp/target"
git -C "$tmp/target" config user.name Test
git -C "$tmp/target" config user.email test@example.com
printf 'base\n' >"$tmp/target/README.md"
git -C "$tmp/target" add README.md
git -C "$tmp/target" commit -qm base
base="$(git -C "$tmp/target" rev-parse HEAD)"
git -C "$tmp/target" checkout -q --detach
printf 'changed\n' >>"$tmp/target/README.md"
mkdir -p "$tmp/target/src"
printf 'new source\n' >"$tmp/target/src/module.txt"
echo 'Test issue' >"$tmp/title.txt"

(
  cd "$tmp/target"
  BRANCH=ai/issue-7 BASE_SHA="$base" RUNNER_TEMP="$tmp" \
    PR_SUMMARY_FILE="$tmp/summary.md" bash "$here/checkpoint-on-failure.sh" >/dev/null
  [ "$(git branch --show-current)" = ai/issue-7 ]
  [ -z "$(git status --porcelain)" ]
  git show --stat --oneline HEAD | grep -q 'src/module.txt'
  grep -q 'Incomplete recovery checkpoint' "$tmp/summary.md"
  BRANCH=ai/issue-7 BASE_SHA="$base" ARTIFACT_DIR="$tmp/artifact" \
    PR_SUMMARY_FILE="$tmp/summary.md" ISSUE_TITLE_FILE="$tmp/title.txt" \
    COMPLEXITY=medium MODEL=test-model AUTOMATION_SHA=1111111111111111111111111111111111111111 \
    bash "$here/export-changes.sh" >/dev/null
)
git clone -q "$tmp/target" "$tmp/trusted"
git -C "$tmp/trusted" checkout -q "$base"
ARTIFACT_DIR="$tmp/artifact" TRUSTED_REPO="$tmp/trusted" BASE_SHA="$base" \
  BRANCH=ai/issue-7 ISSUE_NUMBER=7 WORK_DIR="$tmp/validated-work" \
  AUTOMATION_SHA=1111111111111111111111111111111111111111 \
  bash "$here/validate-changes.sh" >/dev/null
grep -q 'new source' "$tmp/validated-work/src/module.txt"
echo 'PASS: interrupted tracked and new work survives fresh validation'

if (cd "$tmp/target" && BRANCH=ai/issue-8 BASE_SHA="$base" RUNNER_TEMP="$tmp" \
  PR_SUMMARY_FILE="$tmp/wrong.md" bash "$here/checkpoint-on-failure.sh" >/dev/null 2>&1); then
  echo 'FAIL: checkpoint accepted the wrong branch' >&2
  exit 1
fi
echo 'PASS: checkpoint refuses an unexpected branch'
