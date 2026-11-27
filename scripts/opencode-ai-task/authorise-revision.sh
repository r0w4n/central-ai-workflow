#!/usr/bin/env bash
#
# Pure policy gate for pull-request revision requests. Network/API lookups are
# performed by revision-gate.sh; this script only evaluates the resulting
# trusted fields so the policy can be unit-tested without GitHub access.

set -euo pipefail

required_author="${GATE_REQUIRED_AUTHOR:?GATE_REQUIRED_AUTHOR is required}"
expected_pr_author="${GATE_EXPECTED_PR_AUTHOR:?GATE_EXPECTED_PR_AUTHOR is required}"
expected_repository="${GATE_EXPECTED_REPOSITORY:?GATE_EXPECTED_REPOSITORY is required}"
approved_base="${GATE_APPROVED_BASE:?GATE_APPROVED_BASE is required}"

deny() { echo "proceed=false reason=$1"; exit 0; }
allow() { echo "proceed=true reason=$1"; exit 0; }
lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

comment_body="${GATE_COMMENT_BODY:-}"
prefix='/ai revise'

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

[ "${GATE_COMMENT_USER_TYPE:-}" = User ] || deny "revision author must be a human GitHub user"
[ "$(lowercase "${GATE_COMMENT_AUTHOR:-}")" = "$(lowercase "$required_author")" ] ||
  deny "revision author is not authorised"
[ "$(lowercase "${GATE_TRIGGER_ACTOR:-}")" = "$(lowercase "$required_author")" ] ||
  deny "workflow actor is not authorised"

[ "${comment_body#"$prefix"}" != "$comment_body" ] || deny "comment does not start with /ai revise"
feedback="${comment_body#"$prefix"}"
case "$feedback" in
  '') deny "revision feedback is empty" ;;
  [!$' \t\r\n']*) deny "the /ai revise command must be followed by whitespace" ;;
esac
printf '%s' "$feedback" | grep -q '[^[:space:]]' || deny "revision feedback is empty"

[ "${GATE_ISSUE_STATE:-}" = open ] || deny "linked issue is not open"
[ "$(lowercase "${GATE_ISSUE_AUTHOR:-}")" = "$(lowercase "$required_author")" ] ||
  deny "linked issue author is not authorised"
[ "${GATE_ISSUE_LABELLED:-false}" = true ] || deny "linked issue lacks the required AI label"
[ "${GATE_ISSUE_BODY_NONEMPTY:-false}" = true ] || deny "linked issue description is empty"

allow "revision request, pull request provenance and linked issue verified"
