#!/usr/bin/env bash
# Fetch and revalidate all GitHub state for one PR revision request.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
COMMENT_ID="${COMMENT_ID:?COMMENT_ID is required}"
REQUIRED_AUTHOR="${REQUIRED_AUTHOR:?REQUIRED_AUTHOR is required}"
EXPECTED_PR_AUTHOR="${EXPECTED_PR_AUTHOR:?EXPECTED_PR_AUTHOR is required}"
APPROVED_BASE_BRANCH="${APPROVED_BASE_BRANCH:?APPROVED_BASE_BRANCH is required}"
TRIGGER_ACTOR="${TRIGGER_ACTOR:?TRIGGER_ACTOR is required}"
REQUIRED_LABEL="${REQUIRED_LABEL:-ai-task}"

fail() { echo "::error::$1" >&2; exit 1; }
require_numeric "$PR_NUMBER" || fail "pr_number must be numeric"
require_numeric "$COMMENT_ID" || fail "comment_id must be numeric"

PR_DATA="$(gh api "repos/${REPOSITORY}/pulls/${PR_NUMBER}")" || fail "could not read pull request #${PR_NUMBER}"
COMMENT_DATA="$(gh api "repos/${REPOSITORY}/issues/comments/${COMMENT_ID}")" || fail "could not read comment ${COMMENT_ID}"

COMMENT_PR_NUMBER="$(jq -r '.issue_url | split("/") | last' <<<"${COMMENT_DATA}")"
[ "$COMMENT_PR_NUMBER" = "$PR_NUMBER" ] || {
  echo "proceed=false reason=comment does not belong to pull request #${PR_NUMBER}"
  exit 0
}

BRANCH="$(jq -r '.head.ref // ""' <<<"${PR_DATA}")"
if [[ "$BRANCH" =~ ^ai/issue-([0-9]+)$ ]]; then
  ISSUE_NUMBER="${BASH_REMATCH[1]}"
else
  ISSUE_NUMBER=0
fi

ISSUE_DATA='{}'
if [ "$ISSUE_NUMBER" != 0 ]; then
  ISSUE_DATA="$(gh api "repos/${REPOSITORY}/issues/${ISSUE_NUMBER}")" || fail "could not read linked issue #${ISSUE_NUMBER}"
fi

PR_BODY="$(jq -r '.body // ""' <<<"${PR_DATA}")"
PR_MARKER=false
if grep -qE '<!-- central-ai-generated-pr -->|Created automatically by OpenCode from issue #[0-9]+' <<<"${PR_BODY}"; then
  PR_MARKER=true
fi

GATE_REQUIRED_AUTHOR="$REQUIRED_AUTHOR"
GATE_EXPECTED_PR_AUTHOR="$EXPECTED_PR_AUTHOR"
GATE_EXPECTED_REPOSITORY="$REPOSITORY"
GATE_APPROVED_BASE="$APPROVED_BASE_BRANCH"
GATE_PR_STATE="$(jq -r '.state // ""' <<<"${PR_DATA}")"
GATE_PR_MERGED="$(jq -r '.merged // false' <<<"${PR_DATA}")"
GATE_PR_BASE="$(jq -r '.base.ref // ""' <<<"${PR_DATA}")"
GATE_PR_HEAD_REPOSITORY="$(jq -r '.head.repo.full_name // ""' <<<"${PR_DATA}")"
GATE_PR_HEAD_BRANCH="$BRANCH"
GATE_PR_AUTHOR="$(jq -r '.user.login // ""' <<<"${PR_DATA}")"
GATE_PR_AUTOMATION_MARKER="$PR_MARKER"
GATE_COMMENT_AUTHOR="$(jq -r '.user.login // ""' <<<"${COMMENT_DATA}")"
GATE_COMMENT_USER_TYPE="$(jq -r '.user.type // ""' <<<"${COMMENT_DATA}")"
GATE_COMMENT_BODY="$(jq -r '.body // ""' <<<"${COMMENT_DATA}")"
GATE_TRIGGER_ACTOR="$TRIGGER_ACTOR"
GATE_ISSUE_NUMBER="$ISSUE_NUMBER"
GATE_ISSUE_STATE="$(jq -r '.state // ""' <<<"${ISSUE_DATA}")"
GATE_ISSUE_AUTHOR="$(jq -r '.user.login // ""' <<<"${ISSUE_DATA}")"
GATE_ISSUE_BODY_NONEMPTY="$(jq -r 'if ((.body // "") | length) > 0 then "true" else "false" end' <<<"${ISSUE_DATA}")"
GATE_ISSUE_LABELLED="$(jq -r --arg label "$REQUIRED_LABEL" 'if any(.labels[]?; .name == $label) then "true" else "false" end' <<<"${ISSUE_DATA}")"
export GATE_REQUIRED_AUTHOR GATE_EXPECTED_PR_AUTHOR GATE_EXPECTED_REPOSITORY GATE_APPROVED_BASE
export GATE_PR_STATE GATE_PR_MERGED GATE_PR_BASE GATE_PR_HEAD_REPOSITORY GATE_PR_HEAD_BRANCH
export GATE_PR_AUTHOR GATE_PR_AUTOMATION_MARKER GATE_COMMENT_AUTHOR GATE_COMMENT_USER_TYPE
export GATE_COMMENT_BODY GATE_TRIGGER_ACTOR GATE_ISSUE_NUMBER GATE_ISSUE_STATE GATE_ISSUE_AUTHOR
export GATE_ISSUE_BODY_NONEMPTY GATE_ISSUE_LABELLED

DECISION="$(bash "$(dirname "$0")/authorise-revision.sh")"
echo "$DECISION"
if grep -q '^proceed=true' <<<"$DECISION"; then
  echo "issue_number=${ISSUE_NUMBER}"
  echo "pr_number=${PR_NUMBER}"
  echo "comment_id=${COMMENT_ID}"
  echo "branch=${BRANCH}"
  echo "base_sha=$(jq -r '.head.sha // ""' <<<"${PR_DATA}")"
fi
