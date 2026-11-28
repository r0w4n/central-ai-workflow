#!/usr/bin/env bash
#
# Fetch and revalidate all GitHub state for one automated CI-remediation
# decision, then delegate the policy to the pure remediation-authorise.sh.
#
# Reads the persistent remediation state (single sticky PR comment), the pull
# request, the linked issue and the check runs of the CURRENT head commit.
# Stale events for superseded commits never reach the policy: the check runs
# are always fetched for the head commit that exists right now.
#
# Inputs (environment):
#   REPOSITORY, PR_NUMBER, REMEDIATION_EVENT (checks-failed|checks-passed)
#   REQUIRED_AUTHOR, EXPECTED_PR_AUTHOR, APPROVED_BASE_BRANCH
#   TRIGGER_ACTOR, REQUIRED_LABEL
#   MAX_ATTEMPTS        optional attempt limit (default 3)
#   CURRENT_RUN_ID      optional: this run's id (in-progress recheck)
# Output: key=value lines; consumed by the authorise job's decision step.
#
# Check-run listing failures exit non-zero with an explicit ::error
# diagnostic (the caller needs 'checks: read' and 'actions: read'); they are
# never silently treated as "no failing checks".

set -euo pipefail

. "$(dirname "$0")/lib.sh"

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
REMEDIATION_EVENT="${REMEDIATION_EVENT:?REMEDIATION_EVENT is required}"
REQUIRED_AUTHOR="${REQUIRED_AUTHOR:?REQUIRED_AUTHOR is required}"
EXPECTED_PR_AUTHOR="${EXPECTED_PR_AUTHOR:?EXPECTED_PR_AUTHOR is required}"
APPROVED_BASE_BRANCH="${APPROVED_BASE_BRANCH:?APPROVED_BASE_BRANCH is required}"
TRIGGER_ACTOR="${TRIGGER_ACTOR:?TRIGGER_ACTOR is required}"
REQUIRED_LABEL="${REQUIRED_LABEL:-ai-task}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
CURRENT_RUN_ID="${CURRENT_RUN_ID:-}"

fail() { echo "::error::$1" >&2; exit 1; }
require_numeric "${PR_NUMBER}" || fail "pr_number must be numeric"

STATE_MARKER="<!-- central-ai-remediation pr=${PR_NUMBER} "

PR_DATA="$(gh api "repos/${REPOSITORY}/pulls/${PR_NUMBER}")" ||
  fail "could not read pull request #${PR_NUMBER}"
HEAD_SHA="$(jq -r '.head.sha // ""' <<<"${PR_DATA}")"
BRANCH="$(jq -r '.head.ref // ""' <<<"${PR_DATA}")"
if [[ "${BRANCH}" =~ ^ai/issue-([0-9]+)$ ]]; then
  ISSUE_NUMBER="${BASH_REMATCH[1]}"
else
  ISSUE_NUMBER=0
fi

ISSUE_DATA='{}'
if [ "${ISSUE_NUMBER}" != 0 ]; then
  ISSUE_DATA="$(gh api "repos/${REPOSITORY}/issues/${ISSUE_NUMBER}")" ||
    fail "could not read linked issue #${ISSUE_NUMBER}"
fi

PR_BODY="$(jq -r '.body // ""' <<<"${PR_DATA}")"
PR_MARKER=false
if grep -qE '<!-- central-ai-generated-pr -->|Created automatically by OpenCode from issue #[0-9]+' <<<"${PR_BODY}"; then
  PR_MARKER=true
fi

# --- Persistent remediation state: the single sticky remediation comment -----
STATE_STATUS=none
STATE_EPISODE_SHA=""
STATE_LAST_HEAD=""
STATE_ATTEMPT=0
STATE_MAX=""
STATE_RUN_ID=""
STATE_UPDATED_AT=0
STATE_COMMENT_ID=""
COMMENTS="$(gh api --paginate "repos/${REPOSITORY}/issues/${PR_NUMBER}/comments" --jq '.[] | [.id, .updated_at, .body] | @tsv')" || {
  echo "::error::Could not list PR #${PR_NUMBER} comments (GET /issues/${PR_NUMBER}/comments); the authorise job needs pull-requests: read." >&2
  exit 1
}
while IFS=$'\t' read -r COMMENT_ID COMMENT_UPDATED COMMENT_BODY; do
  case "${COMMENT_BODY}" in
    *"<!-- central-ai-remediation pr=${PR_NUMBER} "*) ;;
    *) continue ;;
  esac
  STATE_COMMENT_ID="${COMMENT_ID}"
  STATE_UPDATED_AT="$(jq -rn --arg t "${COMMENT_UPDATED}" '$t | fromdateiso8601')"
  PARSED_STATUS="$(sed -n 's/.*central-ai-remediation pr='"${PR_NUMBER}"' episode=\([^ ]*\) attempt=\([0-9]*\) max=\([0-9]*\) status=\([^ ]*\) run=\([^ ]*\) head=\([^ ]*\).*/\4/p' <<<"${COMMENT_BODY}" | head -n 1)"
  if [ -n "${PARSED_STATUS}" ]; then
    STATE_STATUS="${PARSED_STATUS}"
    STATE_EPISODE_SHA="$(sed -n 's/.*episode=\([^ ]*\).*/\1/p' <<<"${COMMENT_BODY}" | head -n 1)"
    STATE_ATTEMPT="$(sed -n 's/.*attempt=\([0-9]*\).*/\1/p' <<<"${COMMENT_BODY}" | head -n 1)"
    STATE_MAX="$(sed -n 's/.* max=\([0-9]*\) .*/\1/p' <<<"${COMMENT_BODY}" | head -n 1)"
    STATE_RUN_ID="$(sed -n 's/.*run=\([^ ]*\).*/\1/p' <<<"${COMMENT_BODY}" | head -n 1)"
    STATE_LAST_HEAD="$(sed -n 's/.*head=\([^ ]*\).*/\1/p' <<<"${COMMENT_BODY}" | head -n 1)"
  fi
done <<<"${COMMENTS}"
[ -z "${STATE_COMMENT_ID}" ] && STATE_STATUS=none

# --- Check runs of the current head -------------------------------------------
# An API failure must be distinguishable from a verified empty or green
# result: a 403/500 here aborts with an explicit diagnostic instead of being
# silently converted into "no failed checks".
CHECK_ROWS="$(gh api --paginate "repos/${REPOSITORY}/commits/${HEAD_SHA}/check-runs?per_page=100" \
  --jq '.check_runs[] | [.status, (.conclusion // ""), (.name // "")] | @tsv')" || {
  echo "::error::Could not list check runs for ${HEAD_SHA:0:12} (GET /repos/${REPOSITORY}/commits/<sha>/check-runs). Failing checks cannot be verified; grant the caller workflow 'checks: read' (job-log excerpts additionally need 'actions: read') and retry." >&2
  exit 1
}
FAILED_CHECKS=""
COMPLETED_TOTAL=0
PENDING_TOTAL=0
while IFS=$'\t' read -r CR_STATUS CR_CONCLUSION CR_NAME; do
  [ -n "${CR_STATUS}" ] || continue
  if [ "${CR_STATUS}" != "completed" ]; then
    PENDING_TOTAL=$((PENDING_TOTAL + 1))
    continue
  fi
  COMPLETED_TOTAL=$((COMPLETED_TOTAL + 1))
  case "${CR_CONCLUSION}" in
    failure | timed_out | startup_failure | action_required)
      FAILED_CHECKS+="${CR_NAME}"$'\n'
      ;;
  esac
done <<<"${CHECK_ROWS}"
FAILED_CHECKS="$(printf '%s' "${FAILED_CHECKS}" | sort -u | paste -sd'|' -)"

# --- Relation of the current head to the episode's last known head ------------
RELATION=none
if [ -n "${STATE_LAST_HEAD}" ]; then
  if [ "${STATE_LAST_HEAD}" = "${HEAD_SHA}" ]; then
    RELATION=identical
  else
    RELATION="$(gh api "repos/${REPOSITORY}/compare/${STATE_LAST_HEAD}...${HEAD_SHA}" --jq '.status // "diverged"' 2>/dev/null)" || RELATION=diverged
    case "${RELATION}" in ahead | behind | identical | diverged) ;; *) RELATION=diverged ;; esac
  fi
fi

DECISION="$(GATE_REMEDIATION_EVENT="${REMEDIATION_EVENT}" \
  GATE_FAILED_CHECKS="${FAILED_CHECKS}" \
  GATE_PR_STATE="$(jq -r '.state // ""' <<<"${PR_DATA}")" \
  GATE_PR_MERGED="$(jq -r '.merged // false' <<<"${PR_DATA}")" \
  GATE_PR_BASE="$(jq -r '.base.ref // ""' <<<"${PR_DATA}")" \
  GATE_PR_HEAD_REPOSITORY="$(jq -r '.head.repo.full_name // ""' <<<"${PR_DATA}")" \
  GATE_PR_HEAD_BRANCH="${BRANCH}" \
  GATE_PR_AUTHOR="$(jq -r '.user.login // ""' <<<"${PR_DATA}")" \
  GATE_PR_AUTOMATION_MARKER="${PR_MARKER}" \
  GATE_EXPECTED_PR_AUTHOR="${EXPECTED_PR_AUTHOR}" \
  GATE_EXPECTED_REPOSITORY="${REPOSITORY}" \
  GATE_APPROVED_BASE="${APPROVED_BASE_BRANCH}" \
  GATE_REQUIRED_AUTHOR="${REQUIRED_AUTHOR}" \
  GATE_TRIGGER_ACTOR="${TRIGGER_ACTOR}" \
  GATE_ISSUE_NUMBER="${ISSUE_NUMBER}" \
  GATE_ISSUE_STATE="$(jq -r '.state // ""' <<<"${ISSUE_DATA}")" \
  GATE_ISSUE_AUTHOR="$(jq -r '.user.login // ""' <<<"${ISSUE_DATA}")" \
  GATE_ISSUE_LABELLED="$(jq -r --arg label "${REQUIRED_LABEL}" 'if any(.labels[]?; .name == $label) then "true" else "false" end' <<<"${ISSUE_DATA}")" \
  GATE_ISSUE_BODY_NONEMPTY="$(jq -r 'if ((.body // "") | length) > 0 then "true" else "false" end' <<<"${ISSUE_DATA}")" \
  GATE_EPISODE_STATUS="${STATE_STATUS}" \
  GATE_EPISODE_SHA="${STATE_EPISODE_SHA}" \
  GATE_EPISODE_LAST_HEAD="${STATE_LAST_HEAD}" \
  GATE_EPISODE_ATTEMPT="${STATE_ATTEMPT}" \
  GATE_EPISODE_MAX="${STATE_MAX}" \
  GATE_EPISODE_RUN_ID="${STATE_RUN_ID}" \
  GATE_EPISODE_UPDATED_AT="${STATE_UPDATED_AT}" \
  GATE_HEAD_SHA="${HEAD_SHA}" \
  GATE_HEAD_RELATION="${RELATION}" \
  GATE_CHECK_TOTAL="${COMPLETED_TOTAL}" \
  GATE_PENDING_CHECKS="${PENDING_TOTAL}" \
  GATE_MAX_ATTEMPTS="${MAX_ATTEMPTS}" \
  GATE_CURRENT_RUN_ID="${CURRENT_RUN_ID}" \
  bash "$(dirname "$0")/remediation-authorise.sh")"

printf '%s\n' "${DECISION}"
printf 'issue_number=%s\n' "${ISSUE_NUMBER}"
printf 'pr_number=%s\n' "${PR_NUMBER}"
printf 'branch=%s\n' "${BRANCH}"
printf 'base_sha=%s\n' "${HEAD_SHA}"
printf 'failed_checks=%s\n' "${FAILED_CHECKS}"
printf 'status_comment_id=%s\n' "${STATE_COMMENT_ID}"
printf 'episode_status=%s\n' "${STATE_STATUS}"
if [ -n "${STATE_EPISODE_SHA}" ]; then
  printf 'episode_sha=%s\n' "${STATE_EPISODE_SHA}"
else
  printf 'episode_sha=%s\n' "${HEAD_SHA}"
fi
