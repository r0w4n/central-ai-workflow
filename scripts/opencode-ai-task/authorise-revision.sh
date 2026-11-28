#!/usr/bin/env bash
#
# Pure policy gate for pull-request revision requests. Network/API lookups are
# performed by revision-gate.sh; this script only evaluates the resulting
# trusted fields so the policy can be unit-tested without GitHub access.
#
# Feedback model: an authorised human may either use the explicit
# "/ai revise <feedback>" command or write an ordinary actionable comment.
# Bot comments, automation status updates, non-actionable discussion and
# unauthorised feedback are ignored silently. Recognised but malformed
# commands and under-specified feedback from the authorised user always get an
# acknowledgement reply (acknowledge=public), never silence.

set -euo pipefail

required_author="${GATE_REQUIRED_AUTHOR:?GATE_REQUIRED_AUTHOR is required}"
expected_pr_author="${GATE_EXPECTED_PR_AUTHOR:?GATE_EXPECTED_PR_AUTHOR is required}"
expected_repository="${GATE_EXPECTED_REPOSITORY:?GATE_EXPECTED_REPOSITORY is required}"
approved_base="${GATE_APPROVED_BASE:?GATE_APPROVED_BASE is required}"

here="$(dirname "$0")"
deny() { echo "proceed=false reason=$1 acknowledge=${2:-silent}"; exit 0; }
allow() { echo "proceed=true reason=$1 acknowledge=public"; exit 0; }
lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

comment_body="${GATE_COMMENT_BODY:-}"

[ "${GATE_PR_STATE:-}" = open ] || deny "pull request is not open"
[ "${GATE_PR_MERGED:-false}" = false ] || deny "pull request is already merged"
[ "${GATE_PR_BASE:-}" = "$approved_base" ] || deny "pull request base is not approved"
[ "${GATE_PR_HEAD_REPOSITORY:-}" = "$expected_repository" ] || deny "pull request head is not in the expected repository"

if ! [[ "${GATE_PR_HEAD_BRANCH:-}" =~ ^ai/issue-([0-9]+)$ ]]; then
  deny "pull request head is not an approved AI branch"
fi
[ "${BASH_REMATCH[1]}" = "${GATE_ISSUE_NUMBER:-}" ] || deny "pull request branch does not identify the linked issue"

[ "$(lowercase "${GATE_PR_AUTHOR:-}")" = "$(lowercase "$expected_pr_author")" ] ||
  deny "pull request was not created by the approved automation"
[ "${GATE_PR_AUTOMATION_MARKER:-false}" = true ] || deny "pull request lacks Central AI provenance"

# From here on the requester may be the authorised human; comment-content
# problems are answered publicly. Everything before this point is a
# repository-provenance problem and is ignored silently.
[ "${GATE_COMMENT_USER_TYPE:-}" = User ] || deny "revision author must be a human GitHub user"
[ "$(lowercase "${GATE_COMMENT_AUTHOR:-}")" = "$(lowercase "$required_author")" ] ||
  deny "revision author is not authorised"
[ "$(lowercase "${GATE_TRIGGER_ACTOR:-}")" = "$(lowercase "$required_author")" ] ||
  deny "workflow actor is not authorised"

CLASSIFICATION="$(GATE_COMMENT_BODY="${comment_body}" bash "${here}/feedback-classify.sh")"
CLASS="$(sed -n 's/^class=//p' <<<"${CLASSIFICATION}")"
FEEDBACK="$(sed -n 's/^feedback=//p' <<<"${CLASSIFICATION}")"

case "${CLASS}" in
  revise)
    : ;;
  feedback)
    # Ordinary actionable feedback: the whole comment is the request.
    FEEDBACK="${comment_body}"
    ;;
  revise-empty)
    deny "the /ai revise command must be followed by feedback describing the requested change" public
    ;;
  unknown-command)
    deny "the /ai command '${comment_body}' is not recognised; use '/ai revise <feedback>' or write the requested change as an ordinary comment" public
    ;;
  clarify)
    deny "the comment does not describe a concrete change; reply with the specific change you want, or use '/ai revise <feedback>'" public
    ;;
  non-actionable)
    deny "comment is a reaction or status note, not actionable feedback" silent
    ;;
  *)
    deny "comment could not be classified" silent
    ;;
esac

[ -n "${FEEDBACK}" ] && printf '%s' "${FEEDBACK}" | grep -q '[^[:space:]]' ||
  deny "revision feedback is empty" public

[ "${GATE_ISSUE_STATE:-}" = open ] || deny "linked issue is not open" public
[ "$(lowercase "${GATE_ISSUE_AUTHOR:-}")" = "$(lowercase "$required_author")" ] ||
  deny "linked issue author is not authorised" public
[ "${GATE_ISSUE_LABELLED:-false}" = true ] || deny "linked issue lacks the required AI label" public
[ "${GATE_ISSUE_BODY_NONEMPTY:-false}" = true ] || deny "linked issue description is empty" public

allow "revision request, pull request provenance and linked issue verified"
