#!/usr/bin/env bash
# Preserve a failed agent's useful work as an ordinary, restricted patch series.
# The result is untrusted until validate-changes.sh checks it on a fresh runner.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

BRANCH="${BRANCH:?BRANCH is required}"
BASE_SHA="${BASE_SHA:?BASE_SHA is required}"
PR_SUMMARY_FILE="${PR_SUMMARY_FILE:?PR_SUMMARY_FILE is required}"
RUNNER_TEMP="${RUNNER_TEMP:?RUNNER_TEMP is required}"

require_numeric "${BRANCH#ai/issue-}" || {
  echo "::error::invalid task branch" >&2
  exit 1
}
[ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" = "$(pwd -P)" ] || {
  echo "::error::checkpoint must run at the target repository root" >&2
  exit 1
}
current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [ -z "$current_branch" ] && [ "$(git rev-parse HEAD)" = "$BASE_SHA" ]; then
  git switch -c "$BRANCH"
elif [ "$current_branch" != "$BRANCH" ]; then
  echo "::error::cannot checkpoint unexpected branch '$current_branch'" >&2
  exit 1
fi
git merge-base --is-ancestor "$BASE_SHA" HEAD || {
  echo "::error::checkpoint history does not descend from the pinned base" >&2
  exit 1
}

# Git ignore rules prevent generated dependencies and local secrets from being
# added. Any staged paths still pass the same fresh-runner protected-path and
# file-mode validation as a successful implementation.
git add -A -- .
if ! git diff --cached --quiet; then
  hooks_dir="${RUNNER_TEMP}/checkpoint-no-hooks"
  mkdir -p "$hooks_dir"
  git -c core.hooksPath="$hooks_dir" -c commit.gpgsign=false \
    commit -m "wip: preserve interrupted AI task checkpoint"
fi
if [ "$(git rev-list --count "${BASE_SHA}..HEAD")" -lt 1 ]; then
  echo "::warning::No implementation changes were available to checkpoint."
  exit 2
fi

cat >"$PR_SUMMARY_FILE" <<'SUMMARY'
**Incomplete recovery checkpoint.** The agent stopped before finishing validation.
This branch preserves its commits and remaining tracked changes for a focused
revision. Treat all test results as unverified until the consumer's pull-request
checks run. Review the diff and request `/ai revise` to continue the work.
SUMMARY
echo "::notice::Checkpoint commit created; fresh-runner validation is required before publication."
