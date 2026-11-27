#!/usr/bin/env bash
# Create or update the single audit/status comment for one revision request.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
COMMENT_ID="${COMMENT_ID:?COMMENT_ID is required}"
STATUS="${STATUS:?STATUS is required}"
RUN_URL="${RUN_URL:-}"
RUN_ID="${RUN_ID:-0}"
STATUS_COMMENT_ID="${STATUS_COMMENT_ID:-}"
SUMMARY_FILE="${SUMMARY_FILE:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
COMMENT_FILE="${COMMENT_FILE:-${RUNNER_TEMP:-/tmp}/opencode-revision-status.md}"
STATUS_DRY_RUN="${STATUS_DRY_RUN:-0}"

require_numeric "$PR_NUMBER" || { echo "invalid PR number" >&2; exit 1; }
require_numeric "$COMMENT_ID" || { echo "invalid comment ID" >&2; exit 1; }
case "$STATUS" in accepted|completed|failed|rejected) ;; *) echo "invalid revision status" >&2; exit 1 ;; esac

{
  echo "<!-- central-ai-revision comment=${COMMENT_ID} status=${STATUS} run=${RUN_ID} -->"
  case "$STATUS" in
    accepted)
      echo "### Central AI revision accepted"
      echo
      echo "OpenCode is implementing the feedback from comment ${COMMENT_ID}. Requests for this PR are processed in order."
      ;;
    completed)
      echo "### Central AI revision completed"
      echo
      if [ -n "$COMMIT_SHA" ]; then
        echo "The requested changes were pushed to this PR in commit [\`${COMMIT_SHA:0:12}\`](https://github.com/${REPOSITORY}/commit/${COMMIT_SHA}). Existing checks and preview automation have been triggered again."
      else
        echo "The requested changes were pushed to this PR. Existing checks and preview automation have been triggered again."
      fi
      if [ -n "$SUMMARY_FILE" ] && [ -f "$SUMMARY_FILE" ]; then
        echo
        echo "#### Implementation summary"
        echo
        head -c 6000 "$SUMMARY_FILE"
        echo
      fi
      ;;
    failed)
      echo "### Central AI revision failed"
      echo
      echo "The revision run did not complete successfully. Review the workflow log and current PR head, then retry with the caller workflow's manual \`revision\` mode using PR \`${PR_NUMBER}\` and comment \`${COMMENT_ID}\`. Publication refuses an unexpected head, so a retry cannot silently overwrite another update."
      ;;
    rejected)
      echo "### Central AI revision rejected"
      echo
      echo "${REJECTION_REASON:-The request did not satisfy the revision security policy.}"
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
  STATUS_COMMENT_ID="$(gh api --paginate "repos/${REPOSITORY}/issues/${PR_NUMBER}/comments" --jq ".[] | select(.body | contains(\"<!-- central-ai-revision comment=${COMMENT_ID} \")) | .id" | tail -n 1)"
fi

if [ -n "$STATUS_COMMENT_ID" ]; then
  gh api -X PATCH "repos/${REPOSITORY}/issues/comments/${STATUS_COMMENT_ID}" -F body=@"$COMMENT_FILE" >/dev/null
else
  STATUS_COMMENT_ID="$(gh api -X POST "repos/${REPOSITORY}/issues/${PR_NUMBER}/comments" -F body=@"$COMMENT_FILE" --jq '.id')"
fi
echo "status_comment_id=${STATUS_COMMENT_ID}"
