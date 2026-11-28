#!/usr/bin/env bash
#
# Pure policy gate for automated CI-failure remediation. Network/API lookups
# and episode-state parsing are performed by remediation-gate.sh; this script
# only evaluates the resulting trusted fields so the policy can be
# unit-tested without GitHub access.
#
# Episode model: one remediation episode covers the chain of failing check
# runs that starts on the first failing head commit and continues across the
# commits the remediation itself pushes. Attempts are counted per episode and
# bounded by GATE_MAX_ATTEMPTS (default 3). A head that is not a descendant
# of the episode's last known head starts a fresh episode.
#
# Inputs (all environment):
#   GATE_REMEDIATION_EVENT   checks-failed | checks-passed
#   GATE_FAILED_CHECKS       pipe-separated failing check names (may be empty)
#   GATE_EPISODE_STATUS      none|in_progress|completed|failed|escalated|ready-for-review
#   GATE_EPISODE_SHA         episode's first failing head commit
#   GATE_EPISODE_LAST_HEAD   latest head commit known to the episode
#   GATE_EPISODE_ATTEMPT     attempts already started for the episode
#   GATE_EPISODE_MAX         attempt limit recorded on the episode
#   GATE_EPISODE_RUN_ID      workflow run that set the in-progress state
#   GATE_EPISODE_UPDATED_AT  epoch seconds of the last state update
#   GATE_HEAD_SHA            current pull-request head commit
#   GATE_HEAD_RELATION       identical|ahead|behind|diverged|none
#                            current head vs GATE_EPISODE_LAST_HEAD
#   GATE_MAX_ATTEMPTS        configured attempt limit (default 3)
#   GATE_CURRENT_RUN_ID      this workflow run (recheck bookkeeping)
#   GATE_NOW                 epoch seconds now (test injection)
#   GATE_STALE_SECONDS       in-progress state older than this is abandoned
#
# Output (key=value):
#   proceed, reason, acknowledge (public|silent), action
#   (remediate|close-episode|escalate|skip), attempt, max_attempts

set -euo pipefail

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_int() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

MAX_ATTEMPTS="$(printf '%s' "${GATE_MAX_ATTEMPTS:-3}" | tr -d '[:space:]')"
is_int "${MAX_ATTEMPTS}" || MAX_ATTEMPTS=3
EPISODE_ATTEMPT="${GATE_EPISODE_ATTEMPT:-0}"
is_int "${EPISODE_ATTEMPT}" || EPISODE_ATTEMPT=0
[ "${MAX_ATTEMPTS}" -ge 1 ] || { echo "proceed=false reason=remediation_max_attempts must be at least 1 acknowledge=silent action=skip"; exit 0; }
[ "${MAX_ATTEMPTS}" -le 10 ] || { echo "proceed=false reason=remediation_max_attempts must be at most 10 acknowledge=silent action=skip"; exit 0; }

# EPISODE_ATTEMPT is updated by advance_attempt/new_episode before finishing.
finish() { # $1 proceed $2 reason $3 acknowledge $4 action
  echo "proceed=$1 reason=$2 acknowledge=$3 action=$4"
  echo "attempt=${EPISODE_ATTEMPT}"
  echo "max_attempts=${MAX_ATTEMPTS}"
  exit 0
}

deny() { finish false "$1" "${2:-silent}" "${3:-skip}"; }
allow() { finish true "$1" "${2:-silent}" "${3:-remediate}"; }

advance_attempt() {
  if [ "$((EPISODE_ATTEMPT + 1))" -gt "${MAX_ATTEMPTS}" ]; then
    return 1
  fi
  EPISODE_ATTEMPT=$((EPISODE_ATTEMPT + 1))
  return 0
}

new_episode() { EPISODE_ATTEMPT=1; }

case "${GATE_REMEDIATION_EVENT:-}" in
  checks-failed | checks-passed) ;;
  *) deny "remediation_event must be checks-failed or checks-passed" silent ;;
esac

# --- Pull-request provenance (same trust level as manual revisions) ----------
[ "${GATE_PR_STATE:-}" = open ] || deny "pull request is not open"
[ "${GATE_PR_MERGED:-false}" = false ] || deny "pull request is already merged"
[ "${GATE_PR_BASE:-}" = "${GATE_APPROVED_BASE:-}" ] || deny "pull request base is not approved"
[ "${GATE_PR_HEAD_REPOSITORY:-}" = "${GATE_EXPECTED_REPOSITORY:-}" ] ||
  deny "pull request head is not in the expected repository"
if ! [[ "${GATE_PR_HEAD_BRANCH:-}" =~ ^ai/issue-([0-9]+)$ ]]; then
  deny "pull request head is not an approved AI branch"
fi
[ "${BASH_REMATCH[1]}" = "${GATE_ISSUE_NUMBER:-}" ] ||
  deny "pull request branch does not identify the linked issue"
[ "$(lowercase "${GATE_PR_AUTHOR:-}")" = "$(lowercase "${GATE_EXPECTED_PR_AUTHOR:-}")" ] ||
  deny "pull request was not created by the approved automation"
[ "${GATE_PR_AUTOMATION_MARKER:-false}" = true ] || deny "pull request lacks Central AI provenance"

# The trigger may be the authorised human, the approved automation App, or the
# repository's own Actions runtime (event router, bounded retry dispatch).
# Anything else is ignored.
actor="$(lowercase "${GATE_TRIGGER_ACTOR:-}")"
author="$(lowercase "${GATE_EXPECTED_PR_AUTHOR:-}")"
author_stripped="${author%\[bot\]}"
author_stripped="${author_stripped##*app/}"
case "${actor}" in
  "$(lowercase "${GATE_REQUIRED_AUTHOR:-}")" | 'github-actions[bot]' | 'app/'"$author_stripped" | "$author_stripped"'[bot]' | "$author_stripped")
    : ;;
  *) deny "remediation trigger actor is not approved" silent ;;
esac

[ "${GATE_ISSUE_STATE:-}" = open ] || deny "linked issue is not open"
[ "$(lowercase "${GATE_ISSUE_AUTHOR:-}")" = "$(lowercase "${GATE_REQUIRED_AUTHOR:-}")" ] ||
  deny "linked issue author is not authorised"
[ "${GATE_ISSUE_LABELLED:-false}" = true ] || deny "linked issue lacks the required AI label"
[ "${GATE_ISSUE_BODY_NONEMPTY:-false}" = true ] || deny "linked issue description is empty"

# --- Episode bookkeeping -------------------------------------------------------
STATUS="${GATE_EPISODE_STATUS:-none}"
case "${STATUS}" in none | in_progress | completed | failed | escalated | ready-for-review) ;;
  *) deny "stored remediation state is invalid (status=${STATUS})" ;;
esac
EPISODE_ATTEMPT="${GATE_EPISODE_ATTEMPT:-0}"
is_int "${EPISODE_ATTEMPT}" || EPISODE_ATTEMPT=0
HEAD_SHA="${GATE_HEAD_SHA:-}"
[ -n "${HEAD_SHA}" ] || deny "current head commit is unknown"
RELATION="${GATE_HEAD_RELATION:-none}"
NOW="${GATE_NOW:-$(date +%s)}"
is_int "${NOW}" || NOW="$(date +%s)"
STALE_SECONDS="${GATE_STALE_SECONDS:-7200}"
is_int "${STALE_SECONDS}" || STALE_SECONDS=7200
UPDATED_AT="${GATE_EPISODE_UPDATED_AT:-0}"
is_int "${UPDATED_AT}" || UPDATED_AT=0
CURRENT_RUN="${GATE_CURRENT_RUN_ID:-}"
EPISODE_RUN="${GATE_EPISODE_RUN_ID:-}"

SAME_HEAD=false
if [ "${RELATION}" = identical ]; then
  SAME_HEAD=true
elif [ "${GATE_EPISODE_LAST_HEAD:-}" = "${HEAD_SHA}" ]; then
  SAME_HEAD=true
elif [ "${RELATION}" = none ] && [ "${GATE_EPISODE_SHA:-}" = "${HEAD_SHA}" ]; then
  SAME_HEAD=true
fi

case "${GATE_REMEDIATION_EVENT}" in
  checks-passed)
    case "${STATUS}" in
      none | escalated) deny "no open remediation episode to close" silent ;;
      ready-for-review) deny "remediation episode is already closed as ready for review" silent ;;
      *) allow "all checks pass; remediation episode closed" public close-episode ;;
    esac
    ;;
  checks-failed)
    [ -n "${GATE_FAILED_CHECKS:-}" ] ||
      deny "no failed checks could be verified for the current head" silent
    case "${STATUS}" in
      none)
        new_episode
        allow "first remediation attempt for failing checks" silent
        ;;
      in_progress)
        if [ -n "${CURRENT_RUN}" ] && [ "${CURRENT_RUN}" = "${EPISODE_RUN}" ]; then
          allow "remediation run recheck for the same run" silent
        fi
        if [ "${SAME_HEAD}" = true ] && [ "$((NOW - UPDATED_AT))" -lt "${STALE_SECONDS}" ]; then
          deny "remediation for this head is already in progress" silent
        fi
        # Abandoned state (runner died, stale takeover) consumes an attempt
        # rather than looping forever.
        if ! advance_attempt; then
          deny "in-progress remediation state is stale and the attempt limit is reached" public escalate
        fi
        allow "taking over a stale in-progress remediation state" silent
        ;;
      completed | failed | ready-for-review)
        if [ "${SAME_HEAD}" = true ] || { [ "${RELATION}" = ahead ] && [ "${STATUS}" = completed ]; }; then
          # Same failure chain: the previous push did not fix the checks, or
          # the previous attempt failed without pushing.
          if ! advance_attempt; then
            deny "remediation attempts exhausted for the repeated failure" public escalate
          fi
          allow "repeated failure: remediation attempt ${EPISODE_ATTEMPT} of ${MAX_ATTEMPTS}" silent
        fi
        # The head is unrelated to the recorded episode: start a fresh episode.
        new_episode
        allow "new failure episode on a new head commit" silent
        ;;
      escalated)
        deny "remediation was escalated; human intervention is required" public skip
        ;;
    esac
    ;;
esac

# finish() always exits; this fallback keeps the contract explicit.
deny "unreachable remediation decision"
