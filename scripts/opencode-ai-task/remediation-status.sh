#!/usr/bin/env bash
#
# Create or update the single persistent remediation status comment for one
# pull request. Every remediation episode for a PR reuses the same comment so
# the owner has one live status record:
#   - current remediation status
#   - failed checks
#   - attempt number and maximum attempts
#   - summary of corrective changes
#   - relevant workflow links and the final outcome
#
# Statuses: in_progress | completed | failed | escalated | ready-for-review
# The HTML marker carries the persistent episode state; remediation-gate.sh
# parses it back for attempt accounting.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
STATUS="${STATUS:?STATUS is required}"
EPISODE_SHA="${EPISODE_SHA:-}"
ATTEMPT="${ATTEMPT:-0}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
FAILED_CHECKS="${FAILED_CHECKS:-}"
HEAD_SHA="${HEAD_SHA:-}"
RUN_URL="${RUN_URL:-}"
RUN_ID="${RUN_ID:-0}"
STATUS_COMMENT_ID="${STATUS_COMMENT_ID:-}"
SUMMARY_FILE="${SUMMARY_FILE:-}"
REASON="${REASON:-}"
COMMENT_FILE="${COMMENT_FILE:-${RUNNER_TEMP:-/tmp}/opencode-remediation-status.md}"
STATUS_DRY_RUN="${STATUS_DRY_RUN:-0}"

require_numeric "$PR_NUMBER" || { echo "invalid PR number" >&2; exit 1; }
require_numeric "$ATTEMPT" || { echo "invalid attempt" >&2; exit 1; }
require_numeric "$MAX_ATTEMPTS" || { echo "invalid max attempts" >&2; exit 1; }
require_numeric "$RUN_ID" || RUN_ID=0
[ -n "${EPISODE_SHA}" ] || { echo "EPISODE_SHA is required" >&2; exit 1; }
case "$STATUS" in in_progress | completed | failed | escalated | ready-for-review) ;;
  *) echo "invalid remediation status" >&2; exit 1 ;;
esac

episode_sha_short="${EPISODE_SHA:0:12}"

checks_list() {
  if [ -z "$FAILED_CHECKS" ]; then
    echo "(none could be verified)"
  else
    printf '%s\n' "$FAILED_CHECKS" | tr '|' '\n' | sed 's/^/- /'
  fi
}

{
  echo "<!-- central-ai-remediation pr=${PR_NUMBER} episode=${EPISODE_SHA} attempt=${ATTEMPT} max=${MAX_ATTEMPTS} status=${STATUS} run=${RUN_ID} head=${HEAD_SHA} -->"
  case "$STATUS" in
    in_progress)
      echo "### Automatic remediation in progress"
      echo
      echo "OpenCode is automatically remediating failed CI checks on this pull request: **attempt ${ATTEMPT} of ${MAX_ATTEMPTS}**."
      echo
      echo "#### Failing checks"
      echo
      checks_list
      ;;
    completed)
      echo "### Automatic remediation pushed"
      echo
      echo "Corrective changes were pushed to this PR in commit [\`${HEAD_SHA:0:12}\`](https://github.com/${REPOSITORY}/commit/${HEAD_SHA}) (attempt ${ATTEMPT} of ${MAX_ATTEMPTS})."
      echo
      echo "CI validation is running again on the updated head. When all required checks pass, this thread is updated with a ready-for-review notification. Merge approval stays manual."
      if [ -n "$SUMMARY_FILE" ] && [ -f "$SUMMARY_FILE" ]; then
        echo
        echo "#### Summary of corrective changes"
        echo
        head -c 6000 "$SUMMARY_FILE"
        echo
      fi
      ;;
    failed)
      echo "### Automatic remediation attempt failed"
      echo
      echo "Attempt ${ATTEMPT} of ${MAX_ATTEMPTS} did not complete successfully. A bounded retry is dispatched automatically; no manual action is needed yet."
      echo
      echo "#### Failing checks"
      echo
      checks_list
      if [ -n "${REASON}" ]; then
        echo
        echo "#### Diagnosis"
        echo
        echo "${REASON}"
      fi
      ;;
    escalated)
      echo "### Automatic remediation limit reached — human intervention required"
      echo
      echo "Automatic remediation did not resolve the failing checks within **${MAX_ATTEMPTS} attempts** (episode started on commit [\`${episode_sha_short}\`](https://github.com/${REPOSITORY}/commit/${EPISODE_SHA})). No further automatic retries will run."
      echo
      echo "#### Failing checks"
      echo
      checks_list
      if [ -n "${REASON}" ]; then
        echo
        echo "#### Diagnosis"
        echo
        echo "${REASON}"
      fi
      echo
      echo "#### Suggested next steps"
      echo
      echo "- Review the linked workflow runs and their uploaded diagnostics artifacts below."
      echo "- Leave the required fix as a comment on this PR (an authorised comment starts a revision automatically), or run the caller workflow's manual revision mode."
      echo "- The underlying issue requirements remain unchanged."
      ;;
    ready-for-review)
      echo "### Automatic remediation successful — ready for human review"
      echo
      echo "All required checks now pass after automatic remediation (attempt ${ATTEMPT} of ${MAX_ATTEMPTS}). The pull request is ready for your functional review and merge approval; nothing is merged automatically."
      ;;
  esac
  if [ -n "$RUN_URL" ]; then
    echo
    echo "Workflow run: ${RUN_URL}"
  fi
} >"$COMMENT_FILE"

if [ "$STATUS_DRY_RUN" = 1 ]; then
  echo "COMMENT_FILE=${COMMENT_FILE}"
  exit 0
fi

if [ -z "$STATUS_COMMENT_ID" ]; then
  if ! STATUS_IDS="$(gh api --paginate "repos/${REPOSITORY}/issues/${PR_NUMBER}/comments" --jq ".[] | select(.body | contains(\"<!-- central-ai-remediation pr=${PR_NUMBER} \")) | .id")"; then
    echo "::error::Could not list PR #${PR_NUMBER} timeline comments (GET /issues/${PR_NUMBER}/comments); this trusted job needs pull-requests: read." >&2
    exit 1
  fi
  STATUS_COMMENT_ID="$(tail -n 1 <<<"${STATUS_IDS}")"
fi

if [ -n "$STATUS_COMMENT_ID" ]; then
  require_numeric "$STATUS_COMMENT_ID" || { echo "::error::invalid status comment ID" >&2; exit 1; }
  if ! gh api -X PATCH "repos/${REPOSITORY}/issues/comments/${STATUS_COMMENT_ID}" -F body=@"$COMMENT_FILE" >/dev/null; then
    echo "::error::Could not update PR #${PR_NUMBER} remediation status (PATCH /issues/comments/${STATUS_COMMENT_ID}); this trusted job needs pull-requests: write for PR timeline comments." >&2
    exit 1
  fi
else
  if ! STATUS_COMMENT_ID="$(gh api -X POST "repos/${REPOSITORY}/issues/${PR_NUMBER}/comments" -F body=@"$COMMENT_FILE" --jq '.id')"; then
    echo "::error::Could not create PR #${PR_NUMBER} remediation status (POST /issues/${PR_NUMBER}/comments); this trusted job needs pull-requests: write for PR timeline comments. Issues: write alone can return HTTP 403." >&2
    exit 1
  fi
  require_numeric "$STATUS_COMMENT_ID" || { echo "::error::invalid created status comment ID" >&2; exit 1; }
fi
echo "status_comment_id=${STATUS_COMMENT_ID}"
