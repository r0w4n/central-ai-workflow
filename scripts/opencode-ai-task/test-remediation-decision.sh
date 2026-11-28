#!/usr/bin/env bash
#
# Behavioural tests for remediation-decision.sh: episode-state transitions
# driven by the pure policy decision, with a deterministic gh stub for the
# persistent status comment.
#
# The close-episode decision (proceed=true, action=close-episode) must update
# the status comment to ready-for-review and NEVER start an agent run; the
# escalate decision must stop the loop; a remediate decision writes the
# in-progress comment and keeps going.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

CALL_LOG="$tmp/gh-calls.log"
COMMENT_ID_FILE="$tmp/comment-id"
PATCH_BODY_FILE="$tmp/patch-body.md"
export CALL_LOG COMMENT_ID_FILE PATCH_BODY_FILE

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALL_LOG"
jq_expr=""
prev=""
for arg in "$@"; do
  [ "${prev}" = "--jq" ] && jq_expr="${arg}"
  prev="${arg}"
done
apply() { # $1 = raw response text
  if [ -n "${jq_expr}" ]; then printf '%s' "$1" | jq -r "${jq_expr}"; else printf '%s' "$1"; fi
}
case "$*" in
  *-X\ PATCH*issues/comments/*)
    for arg in "$@"; do
      case "$arg" in body=@*) cat "${arg#body=@}" >"$PATCH_BODY_FILE" 2>/dev/null || printf '(unreadable body)' >"$PATCH_BODY_FILE" ;; esac
    done
    ;;
  *-X\ POST*"issues/"*"/comments"*)
    for arg in "$@"; do
      case "$arg" in body=@*) cat "${arg#body=@}" >"$PATCH_BODY_FILE" 2>/dev/null || printf '(unreadable body)' >"$PATCH_BODY_FILE" ;; esac
    done
    apply "{\"id\":$(cat "$COMMENT_ID_FILE" 2>/dev/null || echo 0)}"
    ;;
  *"issues/42/comments"*) printf '' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

run_decision() { # $1 = gate output; extra env via remaining args
  local gate="$1"
  shift
  env "$@" \
    REPOSITORY=r0w4n/example PR_NUMBER=42 \
    REMEDIATION_EVENT=checks-passed \
    RUN_ID=901 RUN_URL=https://example.invalid/runs/901 \
    GITHUB_OUTPUT="$tmp/github-output.txt" \
    PATH="$tmp/bin:$PATH" \
    bash "${here}/remediation-decision.sh" <<<"$gate"
}

GATE_CLOSE='proceed=true reason=all 14 completed checks pass; remediation episode closed acknowledge=public action=close-episode
attempt=2
max_attempts=3
issue_number=17
pr_number=42
branch=ai/issue-17
base_sha=2222222222222222222222222222222222222222
failed_checks=
status_comment_id=555
episode_status=completed
episode_sha=1111111111111111111111111111111111111111'

echo "$COMMENT_ID_FILE" >/dev/null  # ensure path exists

# --- 1. close-episode closes the episode and never starts an agent -------------
rm -f "$CALL_LOG" "$PATCH_BODY_FILE" "$tmp/github-output.txt"
echo 555 >"$COMMENT_ID_FILE"
OUT="$(run_decision "$GATE_CLOSE" DRY_RUN=false)"
check "a close-episode decision is announced publicly" \
  "grep -q 'ready for human review' '$PATCH_BODY_FILE'"
check "the closed episode records the attempt and limit" \
  "grep -q 'attempt=2 max=3 status=ready-for-review' '$PATCH_BODY_FILE'"
check "the close decision never starts an agent run" \
  "[ \"\$(sed -n 's/^proceed=//p' <<<\"\$OUT\" | head -n 1)\" = false ]"
check "the action is preserved for the workflow" \
  "[ \"\$(sed -n 's/^action=//p' <<<\"\$OUT\" | head -n 1)\" = close-episode ]"
check "no in-progress status is written for a close" \
  "! grep -q 'POST.*/issues/42/comments' '$CALL_LOG'"
check "all expected outputs are emitted" \
  "[ \"\$(sed -n 's/^pr_number=//p' <<<\"\$OUT\" | head -n 1)\" = 42 ] && [ \"\$(sed -n 's/^episode_sha=//p' <<<\"\$OUT\" | head -n 1)\" = 1111111111111111111111111111111111111111 ]"

# --- 2. escalate stops the loop -------------------------------------------------
GATE_ESCALATE='proceed=false reason=remediation attempts exhausted for the repeated failure acknowledge=public action=escalate
attempt=3
max_attempts=3
issue_number=17
pr_number=42
branch=ai/issue-17
base_sha=1111111111111111111111111111111111111111
failed_checks=Quality assurance
status_comment_id=555
episode_status=failed
episode_sha=1111111111111111111111111111111111111111'
rm -f "$CALL_LOG" "$PATCH_BODY_FILE" "$tmp/github-output.txt"
OUT="$(run_decision "$GATE_ESCALATE" DRY_RUN=false)"
check "an escalate decision is announced publicly" \
  "grep -q 'human intervention required' '$PATCH_BODY_FILE'"
check "the escalate decision stops the loop" \
  "[ \"\$(sed -n 's/^proceed=//p' <<<\"\$OUT\" | head -n 1)\" = false ]"
check "the escalation records the reason" \
  "grep -q 'attempts exhausted' '$PATCH_BODY_FILE'"

# --- 3. remediate writes the in-progress status and proceeds --------------------
GATE_REMEDIATE='proceed=true reason=first remediation attempt for failing checks acknowledge=silent action=remediate
attempt=1
max_attempts=3
issue_number=17
pr_number=42
branch=ai/issue-17
base_sha=1111111111111111111111111111111111111111
failed_checks=Quality assurance
status_comment_id=
episode_status=none
episode_sha=1111111111111111111111111111111111111111'
rm -f "$CALL_LOG" "$PATCH_BODY_FILE" "$tmp/github-output.txt"
echo 556 >"$COMMENT_ID_FILE"
OUT="$(run_decision "$GATE_REMEDIATE" DRY_RUN=false)"
check "a remediate decision keeps the agent running" \
  "[ \"\$(sed -n 's/^proceed=//p' <<<\"\$OUT\" | head -n 1)\" = true ]"
check "the in-progress status is created" \
  "grep -q 'Automatic remediation in progress' '$PATCH_BODY_FILE'"
check "the created status comment id is captured" \
  "[ \"\$(sed -n 's/^status_comment_id=//p' <<<\"\$OUT\" | head -n 1)\" = 556 ]"
check "the in-progress marker carries the episode state" \
  "grep -q 'attempt=1 max=3 status=in_progress' '$PATCH_BODY_FILE'"

# --- 4. skip decisions change nothing -------------------------------------------
GATE_SKIP='proceed=false reason=no open authorised AI PR acknowledge=silent action=skip
attempt=0
max_attempts=3
issue_number=0
pr_number=42
branch=
base_sha=
failed_checks=
status_comment_id=
episode_status=none'
rm -f "$CALL_LOG" "$PATCH_BODY_FILE" "$tmp/github-output.txt"
OUT="$(run_decision "$GATE_SKIP" DRY_RUN=false)"
check "a skip decision stops without status changes" \
  "[ \"\$(sed -n 's/^proceed=//p' <<<\"\$OUT\" | head -n 1)\" = false ] && [ ! -s '$PATCH_BODY_FILE' ]"

# --- 5. dry runs announce without writing ---------------------------------------
rm -f "$CALL_LOG" "$PATCH_BODY_FILE" "$tmp/github-output.txt"
OUT="$(run_decision "$GATE_CLOSE" DRY_RUN=true)"
check "a dry-run close announces the decision" "grep -q 'Dry run: would close' <<<\"\$OUT\""
check "a dry-run close writes nothing" "[ ! -s '$PATCH_BODY_FILE' ]"
check "a dry-run close never starts an agent run" \
  "[ \"\$(sed -n 's/^proceed=//p' <<<\"\$OUT\" | head -n 1)\" = false ]"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
