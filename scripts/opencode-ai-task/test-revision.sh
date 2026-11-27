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
export GATE_COMMENT_AUTHOR=r0w4n
export GATE_COMMENT_USER_TYPE=User
export GATE_COMMENT_BODY='/ai revise Fix the drag behavior.'
export GATE_TRIGGER_ACTOR=r0w4n
export GATE_ISSUE_NUMBER=17
export GATE_ISSUE_STATE=open
export GATE_ISSUE_AUTHOR=r0w4n
export GATE_ISSUE_LABELLED=true
export GATE_ISSUE_BODY_NONEMPTY=true

run_gate() { bash "${here}/authorise-revision.sh"; }

OUT="$(run_gate)"
check "valid revision policy is accepted" "grep -q '^proceed=true' <<<\"$OUT\""

GATE_COMMENT_BODY='/ai revise   ' OUT="$(run_gate)"
check "empty feedback is rejected" "grep -q 'feedback is empty' <<<\"$OUT\""
GATE_COMMENT_BODY='/ai revisex do something' OUT="$(run_gate)"
check "command token must have a boundary" "grep -q 'followed by whitespace' <<<\"$OUT\""
GATE_COMMENT_BODY='/ai revise fix it' GATE_COMMENT_AUTHOR=mallory OUT="$(run_gate)"
check "unauthorised human is rejected" "grep -q 'revision author is not authorised' <<<\"$OUT\""
GATE_COMMENT_AUTHOR=r0w4n GATE_COMMENT_USER_TYPE=Bot OUT="$(run_gate)"
check "bot comments are rejected" "grep -q 'must be a human' <<<\"$OUT\""
GATE_COMMENT_USER_TYPE=User GATE_PR_STATE=closed OUT="$(run_gate)"
check "closed PR is rejected" "grep -q 'not open' <<<\"$OUT\""
GATE_PR_STATE=open GATE_PR_MERGED=true OUT="$(run_gate)"
check "merged PR is rejected" "grep -q 'already merged' <<<\"$OUT\""
GATE_PR_MERGED=false GATE_PR_HEAD_REPOSITORY=mallory/fork OUT="$(run_gate)"
check "fork head is rejected" "grep -q 'expected repository' <<<\"$OUT\""
GATE_PR_HEAD_REPOSITORY=r0w4n/example GATE_PR_HEAD_BRANCH=feature/not-ai OUT="$(run_gate)"
check "unexpected head branch is rejected" "grep -q 'approved AI branch' <<<\"$OUT\""
GATE_PR_HEAD_BRANCH=ai/issue-17 GATE_PR_AUTHOR=mallory OUT="$(run_gate)"
check "unexpected PR creator is rejected" "grep -q 'approved automation' <<<\"$OUT\""

# Exercise revision-gate.sh against GitHub-shaped REST payloads through a
# deterministic gh stub. This verifies linkage and field extraction as well as
# the pure policy above.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<FAKEGH
#!/bin/sh
case "\$2" in
  repos/r0w4n/example/pulls/42) cat "$fixtures/pull-request.json" ;;
  repos/r0w4n/example/issues/comments/9001) cat "$fixtures/comment.json" ;;
  repos/r0w4n/example/issues/17) cat "$fixtures/issue.json" ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
FAKEGH
chmod +x "$tmp/bin/gh"
OUT="$(PATH="$tmp/bin:$PATH" REPOSITORY=r0w4n/example PR_NUMBER=42 COMMENT_ID=9001 \
  REQUIRED_AUTHOR=r0w4n EXPECTED_PR_AUTHOR='central-ai-publisher[bot]' \
  APPROVED_BASE_BRANCH=main TRIGGER_ACTOR=r0w4n REQUIRED_LABEL=ai-task \
  bash "${here}/revision-gate.sh")"
check "realistic API payload authorises the revision" "grep -q '^proceed=true' <<<\"$OUT\""
check "gate derives the linked issue" "grep -q '^issue_number=17$' <<<\"$OUT\""
check "gate pins the exact current PR head" "grep -q '^base_sha=1111111111111111111111111111111111111111$' <<<\"$OUT\""

# Status comments are one concise, comment-ID-keyed audit record.
STATUS_DRY_RUN=1 STATUS=completed REPOSITORY=r0w4n/example PR_NUMBER=42 COMMENT_ID=9001 \
  RUN_ID=77 RUN_URL=https://example.invalid/runs/77 COMMIT_SHA=2222222222222222222222222222222222222222 \
  COMMENT_FILE="$tmp/status.md" bash "${here}/revision-status.sh" >/dev/null
check "status marker keys the initiating comment" "grep -q 'comment=9001 status=completed run=77' '$tmp/status.md'"
check "completion links the resulting commit" "grep -q '222222222222' '$tmp/status.md'"
check "completion says checks and previews retrigger" "grep -q 'checks and preview automation' '$tmp/status.md'"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
