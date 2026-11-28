#!/usr/bin/env bash
#
# Drive the episode-state transitions for one remediation authorisation from
# the pure policy decision. Consumed by the workflow's authorise step; the
# wiring lives here so close-episode handling is behavioural-testable.
#
# Reads the key=value gate output (remediation-gate.sh, which embeds the pure
# remediation-authorise.sh decision) on stdin and, for the decision:
#   action=close-episode  -> update the persistent status comment to
#                            ready-for-review and never start an agent run
#   action=escalate       -> update the status comment to escalated and stop
#   action=remediate      -> write the in-progress status comment and keep
#                            going (agent run)
#   action=skip           -> no status change
# Dry runs only announce the decision.
#
# Inputs (environment):
#   REPOSITORY, PR_NUMBER
#   REMEDIATION_EVENT   checks-failed | checks-passed
#   DRY_RUN             true | false (empty means false)
#   RUN_ID, RUN_URL     this workflow run (diagnostics in the status comment)
# Output: key=value lines for GITHUB_OUTPUT:
#   proceed, reason, acknowledge, action, attempt, max_attempts,
#   episode_sha, failed_checks, status_comment_id,
#   issue_number, pr_number, comment_id, branch, base_sha
# Exit 0 always (the decision, not the script, decides failure).

set -euo pipefail

. "$(dirname "$0")/lib.sh"

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
REMEDIATION_EVENT="${REMEDIATION_EVENT:?REMEDIATION_EVENT is required}"
DRY_RUN="${DRY_RUN:-false}"
RUN_ID="${RUN_ID:-0}"
RUN_URL="${RUN_URL:-}"

GATE_OUT="$(cat)"
require_numeric "${PR_NUMBER}" || { echo "::error::pr_number must be numeric" >&2; exit 1; }
case "${REMEDIATION_EVENT}" in
  checks-failed | checks-passed) ;;
  *) echo "::error::remediation_event must be checks-failed or checks-passed" >&2; exit 1 ;;
esac

first_value() { # $1 = key; prints the value of the first "key=value" line on stdin
  sed -n "s/^$1=//p" | head -n 1 | cut -d' ' -f1
}

PROCEED="$(first_value proceed <<<"${GATE_OUT}")"
REASON="$(sed -n 's/^proceed=[a-z]* reason=\(.*\) acknowledge=[a-z]* action=[a-z-]*$/\1/p' <<<"${GATE_OUT}" | head -n 1)"
[ -n "${REASON}" ] || REASON="${GATE_OUT}"
ACK="$(sed -n 's/.*acknowledge=\([a-z]*\).*/\1/p' <<<"${GATE_OUT}" | head -n 1)"
ACTION="$(sed -n 's/.*action=\([a-z-]*\).*/\1/p' <<<"${GATE_OUT}" | head -n 1)"
ATTEMPT="$(first_value attempt <<<"${GATE_OUT}")"
MAX_ATTEMPTS="$(first_value max_attempts <<<"${GATE_OUT}")"
EPISODE_SHA="$(first_value episode_sha <<<"${GATE_OUT}")"
FAILED_CHECKS="$(first_value failed_checks <<<"${GATE_OUT}")"
STATUS_COMMENT_ID="$(first_value status_comment_id <<<"${GATE_OUT}")"
ISSUE_NUMBER="$(first_value issue_number <<<"${GATE_OUT}")"
BRANCH="$(first_value branch <<<"${GATE_OUT}")"
BASE_SHA="$(first_value base_sha <<<"${GATE_OUT}")"
[ -n "${PROCEED}" ] || PROCEED=false
[ -n "${ACK}" ] || ACK=silent
[ -n "${ACTION}" ] || ACTION=skip
[ -n "${ATTEMPT}" ] || ATTEMPT=0
[ -n "${MAX_ATTEMPTS}" ] || MAX_ATTEMPTS=3
[ -n "${EPISODE_SHA}" ] || EPISODE_SHA="${BASE_SHA}"

update_status() { # $1 = status
  STATUS_OUT="$(STATUS="$1" EPISODE_SHA="${EPISODE_SHA}" ATTEMPT="${ATTEMPT}" \
    MAX_ATTEMPTS="${MAX_ATTEMPTS}" FAILED_CHECKS="${FAILED_CHECKS}" \
    STATUS_COMMENT_ID="${STATUS_COMMENT_ID}" RUN_ID="${RUN_ID}" RUN_URL="${RUN_URL}" \
    REASON="${REASON}" \
    REPOSITORY="${REPOSITORY}" PR_NUMBER="${PR_NUMBER}" \
    bash "$(dirname "$0")/remediation-status.sh")"
  STATUS_COMMENT_ID="$(sed -n 's/^status_comment_id=//p' <<<"${STATUS_OUT}")"
}

# Close an open episode when the checks now pass: the policy allows the close
# (proceed=true) but no agent run may follow, so proceed is forced to false
# after the status comment is updated.
if [ "${ACTION}" = close-episode ]; then
  if [ "${DRY_RUN}" != true ]; then
    update_status ready-for-review
  else
    echo "::notice::Dry run: would close the remediation episode as ready for review (no agent run)."
  fi
  PROCEED=false
fi

# Attempt limit reached: escalate with actionable diagnostics and stop the
# loop. (Repeated skips stay silent: stale events and races.)
if [ "${ACTION}" = escalate ]; then
  if [ "${DRY_RUN}" != true ]; then
    update_status escalated
  fi
  PROCEED=false
fi

if [ "${PROCEED}" = true ]; then
  if [ "${DRY_RUN}" = true ]; then
    echo "::notice::Remediation authorised (dry run; no status comment or agent run). ${REASON}"
    PROCEED=false
  else
    update_status in_progress
  fi
fi

{
  echo "proceed=${PROCEED}"
  echo "reason=${REASON}"
  echo "acknowledge=${ACK}"
  echo "task_mode=remediation"
  echo "issue_number=${ISSUE_NUMBER:-0}"
  echo "pr_number=${PR_NUMBER}"
  echo "comment_id=0"
  echo "status_comment_id=${STATUS_COMMENT_ID}"
  echo "branch=${BRANCH:-}"
  echo "base_sha=${BASE_SHA:-}"
  echo "action=${ACTION}"
  echo "attempt=${ATTEMPT}"
  echo "max_attempts=${MAX_ATTEMPTS}"
  echo "episode_sha=${EPISODE_SHA}"
  echo "failed_checks=${FAILED_CHECKS}"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
