#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${here}/fixtures/revision"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

run_gate() { bash "${here}/remediation-authorise.sh"; }

export GATE_REMEDIATION_EVENT=checks-failed
export GATE_FAILED_CHECKS='Quality assurance / code-and-unit|CodeQL (rust)'
export GATE_REQUIRED_AUTHOR=r0w4n
export GATE_EXPECTED_PR_AUTHOR='central-ai-publisher[bot]'
export GATE_EXPECTED_REPOSITORY=r0w4n/example
export GATE_APPROVED_BASE=main
export GATE_PR_STATE=open
export GATE_PR_MERGED=false
export GATE_PR_BASE=main
export GATE_PR_HEAD_REPOSITORY=r0w4n/example
export GATE_PR_HEAD_BRANCH=ai/issue-17
export GATE_PR_AUTHOR='central-ai-publisher[bot]'
export GATE_PR_AUTOMATION_MARKER=true
export GATE_ISSUE_NUMBER=17
export GATE_ISSUE_STATE=open
export GATE_ISSUE_AUTHOR=r0w4n
export GATE_ISSUE_LABELLED=true
export GATE_ISSUE_BODY_NONEMPTY=true
export GATE_TRIGGER_ACTOR='github-actions[bot]'
export GATE_EPISODE_STATUS=none
export GATE_EPISODE_ATTEMPT=0
export GATE_HEAD_SHA=1111111111111111111111111111111111111111
export GATE_HEAD_RELATION=none
export GATE_MAX_ATTEMPTS=3
export GATE_NOW=1000000
export GATE_STALE_SECONDS=7200

OUT="$(run_gate)"
check "first failure starts an episode" "grep -q '^proceed=true' <<<\"$OUT\""
check "first attempt is one" "grep -q '^attempt=1$' <<<\"$OUT\""
check "limit is echoed for the status comment" "grep -q '^max_attempts=3$' <<<\"$OUT\""

GATE_TRIGGER_ACTOR=r0w4n OUT="$(run_gate)"
check "the repository owner may trigger remediation" "grep -q '^proceed=true' <<<\"$OUT\""
GATE_TRIGGER_ACTOR=mallory OUT="$(run_gate)"
check "unapproved trigger actors are ignored" "grep -q '^proceed=false' <<<\"$OUT\""
GATE_TRIGGER_ACTOR='github-actions[bot]' GATE_FAILED_CHECKS='' OUT="$(run_gate)"
check "stale events without verifiable failures are skipped" "grep -q '^proceed=false' <<<\"$OUT\""
GATE_REMEDIATION_EVENT=checks-passed GATE_FAILED_CHECKS='' OUT="$(run_gate)"
check "checks-passed without an episode is skipped" "grep -q 'action=skip' <<<\"$OUT\""
GATE_REMEDIATION_EVENT=checks-passed GATE_EPISODE_STATUS=completed GATE_EPISODE_ATTEMPT=1 GATE_EPISODE_LAST_HEAD=2222222222222222222222222222222222222222 GATE_HEAD_RELATION=identical OUT="$(run_gate)"
check "checks-passed closes the episode" "grep -q 'action=close-episode' <<<\"$OUT\""
check "closing an episode is announced publicly" "grep -q 'acknowledge=public' <<<\"$OUT\""
GATE_PR_AUTHOR=mallory OUT="$(run_gate)"
check "PR provenance is enforced" "grep -q 'approved automation' <<<\"$OUT\""
GATE_PR_AUTHOR='central-ai-publisher[bot]'

# --- Attempt accounting per failure episode -----------------------------------
GATE_REMEDIATION_EVENT=checks-failed
GATE_FAILED_CHECKS='Quality assurance / code-and-unit|CodeQL (rust)'
# Episode failed once on the same head: the retry consumes attempt two.
GATE_EPISODE_STATUS=failed GATE_EPISODE_ATTEMPT=1 GATE_EPISODE_LAST_HEAD=1111111111111111111111111111111111111111 GATE_HEAD_RELATION=identical OUT="$(run_gate)"
check "repeated failure consumes the next attempt" "grep -q '^attempt=2$' <<<\"$OUT\""
# The remediation pushed (completed, head ahead of the recorded push) and CI
# failed again: same episode, attempt two.
GATE_EPISODE_STATUS=completed GATE_EPISODE_ATTEMPT=1 GATE_EPISODE_LAST_HEAD=2222222222222222222222222222222222222222 GATE_HEAD_RELATION=ahead OUT="$(run_gate)"
check "a failed fix on the same chain continues the episode" "grep -q '^attempt=2$' <<<\"$OUT\""
# An unrelated head (force-push) starts a fresh episode.
GATE_EPISODE_STATUS=completed GATE_EPISODE_ATTEMPT=3 GATE_EPISODE_LAST_HEAD=2222222222222222222222222222222222222222 GATE_HEAD_RELATION=diverged OUT="$(run_gate)"
check "an unrelated head starts a fresh episode" "grep -q '^attempt=1$' <<<\"$OUT\""
# Third attempt failed: escalation instead of a fourth run.
GATE_EPISODE_STATUS=failed GATE_EPISODE_ATTEMPT=3 GATE_EPISODE_LAST_HEAD=1111111111111111111111111111111111111111 GATE_HEAD_RELATION=identical OUT="$(run_gate)"
check "the attempt limit escalates to a human" "grep -q 'action=escalate' <<<\"$OUT\""
check "escalation is announced publicly" "grep -q 'acknowledge=public' <<<\"$OUT\""
# An escalated episode never re-runs automatically.
GATE_EPISODE_STATUS=escalated GATE_EPISODE_ATTEMPT=3 OUT="$(run_gate)"
check "escalated episodes require human intervention" "grep -q 'action=skip' <<<\"$OUT\""
# Configurable limit: cap of one escalates after the first attempt.
GATE_EPISODE_STATUS=failed GATE_EPISODE_ATTEMPT=1 GATE_MAX_ATTEMPTS=1 OUT="$(run_gate)"
check "the attempt limit is configurable" "grep -q 'action=escalate' <<<\"$OUT\""
# An in-progress state deduplicates concurrent triggers...
NOW_TS=1000
export GATE_EPISODE_RUN_ID=901
GATE_EPISODE_STATUS=in_progress GATE_EPISODE_ATTEMPT=1 GATE_EPISODE_UPDATED_AT=900 GATE_EPISODE_LAST_HEAD=1111111111111111111111111111111111111111 GATE_HEAD_RELATION=identical GATE_NOW=1000 GATE_MAX_ATTEMPTS=3 OUT="$(run_gate)"
check "in-progress remediation deduplicates triggers" "grep -q 'already in progress' <<<\"$OUT\""
# ...but the owning run may recheck itself (implement job) without advancing.
export GATE_CURRENT_RUN_ID=901
OUT="$(run_gate)"
check "the owning run can recheck its own state" "grep -q '^proceed=true' <<<\"$OUT\""
check "a recheck does not consume an attempt" "grep -q '^attempt=1$' <<<\"$OUT\""
# ...and a stale in-progress state is taken over with attempt accounting.
GATE_CURRENT_RUN_ID='' GATE_NOW=1000000 GATE_EPISODE_UPDATED_AT=1000 OUT="$(run_gate)"
check "abandoned in-progress state is taken over" "grep -q '^attempt=2$' <<<\"$OUT\""
# A ready-for-review episode re-opens when new failures arrive on a new head.
GATE_EPISODE_STATUS=ready-for-review GATE_EPISODE_ATTEMPT=1 GATE_EPISODE_LAST_HEAD=2222222222222222222222222222222222222222 GATE_HEAD_RELATION=diverged OUT="$(run_gate)"
check "new failures after review restart the episode" "grep -q '^attempt=1$' <<<\"$OUT\""

# --- Network gate: deterministic gh stub --------------------------------------
mkdir -p "$tmp/bin"
STATE_COMMENT_ID=555
STATE_BODY='<!-- central-ai-remediation pr=42 episode=1111111111111111111111111111111111111111 attempt=1 max=3 status=failed run=900 head=1111111111111111111111111111111111111111 -->

### Automatic remediation attempt failed'
CHECK_RUNS_PAGE='{"total_count":2,"check_runs":[{"name":"Quality assurance / code-and-unit","id":7001,"status":"completed","conclusion":"failure","details_url":"https://example.invalid/7001"},{"name":"CodeQL (rust)","id":7002,"status":"completed","conclusion":"failure","details_url":"https://example.invalid/7002"},{"name":"fast","id":7003,"status":"completed","conclusion":"success","details_url":""}]}'
cat >"$tmp/bin/gh" <<FAKEGH
#!/usr/bin/env bash
case "\$*" in
  *"pulls/42"*) cat "$fixtures/pull-request.json" ;;
  *"issues/17") cat "$fixtures/issue.json" ;;
  *"issues/42/comments"*) printf '%s\t%s\t%s\n' "${STATE_COMMENT_ID}" "2026-11-27T10:00:00Z" '${STATE_BODY}' ;;
  *"check-runs"*) echo '${CHECK_RUNS_PAGE}' | jq -r '.check_runs[] | select(.status == "completed") | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure" or .conclusion == "action_required") | .name' ;;
  *"compare/"*) echo '{"status":"identical"}' ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
FAKEGH
chmod +x "$tmp/bin/gh"

OUT="$(PATH="$tmp/bin:$PATH" REPOSITORY=r0w4n/example PR_NUMBER=42 REMEDIATION_EVENT=checks-failed \
  REQUIRED_AUTHOR=r0w4n EXPECTED_PR_AUTHOR='central-ai-publisher[bot]' \
  APPROVED_BASE_BRANCH=main TRIGGER_ACTOR='github-actions[bot]' REQUIRED_LABEL=ai-task \
  MAX_ATTEMPTS=3 GATE_NOW=999999999999 \
  bash "${here}/remediation-gate.sh")"
check "gate reads the episode state from the sticky comment" "grep -q '^attempt=2$' <<<\"\$OUT\""
check "gate derives the linked issue" "grep -q '^issue_number=17$' <<<\"\$OUT\""
check "gate pins the current head" "grep -q '^base_sha=1111111111111111111111111111111111111111$' <<<\"\$OUT\""
check "gate lists only failing checks" "grep -q '^failed_checks=CodeQL .rust.|Quality assurance / code-and-unit$' <<<\"\$OUT\""
check "gate returns the state comment id" "grep -q '^status_comment_id=555$' <<<\"\$OUT\""
check "gate repeats the failure episode" "grep -q '^proceed=true' <<<\"\$OUT\""

# A forked head never reaches the policy layer.
cat >"$tmp/bin/gh" <<FAKEGH
#!/usr/bin/env bash
case "\$*" in
  *"pulls/42"*) sed 's/r0w4n\/example/mallory\/fork/' "$fixtures/pull-request.json" ;;
  *"issues/17") cat "$fixtures/issue.json" ;;
  *"issues/42/comments"*) printf '%s\t%s\t%s\n' "${STATE_COMMENT_ID}" "2026-11-27T10:00:00Z" '${STATE_BODY}' ;;
  *"check-runs"*) echo '${CHECK_RUNS_PAGE}' | jq -r '.check_runs[] | select(.status == "completed") | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure" or .conclusion == "action_required") | .name' ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
FAKEGH
chmod +x "$tmp/bin/gh"
OUT="$(PATH="$tmp/bin:$PATH" REPOSITORY=r0w4n/example PR_NUMBER=42 REMEDIATION_EVENT=checks-failed \
  REQUIRED_AUTHOR=r0w4n EXPECTED_PR_AUTHOR='central-ai-publisher[bot]' \
  APPROVED_BASE_BRANCH=main TRIGGER_ACTOR='github-actions[bot]' MAX_ATTEMPTS=3 \
  bash "${here}/remediation-gate.sh")"
check "fork heads are refused before any agent run" "grep -q '^proceed=false' <<<\"\$OUT\""

# --- Status comments ------------------------------------------------------------
STATUS_DRY_RUN=1 STATUS=in_progress REPOSITORY=r0w4n/example PR_NUMBER=42 \
  EPISODE_SHA=1111111111111111111111111111111111111111 ATTEMPT=2 MAX_ATTEMPTS=3 \
  FAILED_CHECKS='CodeQL (rust)|Quality assurance / code-and-unit' RUN_ID=900 \
  RUN_URL=https://example.invalid/runs/900 COMMENT_FILE="$tmp/status.md" \
  bash "${here}/remediation-status.sh" >/dev/null
check "in-progress marker carries the episode state" \
  "grep -q 'central-ai-remediation pr=42 episode=1111111111111111111111111111111111111111 attempt=2 max=3 status=in_progress run=900' '$tmp/status.md'"
check "in-progress lists attempt and limit" "grep -q 'attempt 2 of 3' '$tmp/status.md'"
check "in-progress lists failing checks" "grep -q 'CodeQL (rust)' '$tmp/status.md'"

STATUS_DRY_RUN=1 STATUS=escalated REPOSITORY=r0w4n/example PR_NUMBER=42 \
  EPISODE_SHA=1111111111111111111111111111111111111111 ATTEMPT=3 MAX_ATTEMPTS=3 \
  FAILED_CHECKS='CodeQL (rust)' RUN_ID=900 RUN_URL=https://example.invalid/runs/900 \
  COMMENT_FILE="$tmp/escalated.md" bash "${here}/remediation-status.sh" >/dev/null
check "escalation asks for human intervention" "grep -q 'human intervention required' '$tmp/escalated.md'"
check "escalation documents the episode start" "grep -q '111111111111' '$tmp/escalated.md'"

STATUS_DRY_RUN=1 STATUS=ready-for-review REPOSITORY=r0w4n/example PR_NUMBER=42 \
  EPISODE_SHA=1111111111111111111111111111111111111111 ATTEMPT=2 MAX_ATTEMPTS=3 \
  RUN_ID=900 COMMENT_FILE="$tmp/ready.md" bash "${here}/remediation-status.sh" >/dev/null
check "ready-for-review keeps merging manual" "grep -q 'ready for your functional review and merge approval' '$tmp/ready.md'"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
