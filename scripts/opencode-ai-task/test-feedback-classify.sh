#!/usr/bin/env bash
#
# Behavioural tests for feedback-classify.sh: ordinary actionable comments,
# explicit commands, malformed commands and noise.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

classify() { GATE_COMMENT_BODY="$1" bash "${here}/feedback-classify.sh"; }
class_of() { classify "$1" | sed -n 's/^class=//p'; }

check "explicit revise command is detected" \
  "[ \"\$(class_of '/ai revise please fix the drag handler')\" = revise ]"
check "revise extracts feedback text" \
  "classify '/ai revise  tighten the assertion ' | grep -q '^feedback=tighten the assertion$'"
check "bare /ai revise is malformed" \
  "[ \"\$(class_of '/ai revise')\" = revise-empty ]"
check "whitespace-only revise is malformed" \
  "[ \"\$(class_of '/ai revise   ')\" = revise-empty ]"
check "revisex is malformed" \
  "[ \"\$(class_of '/ai revisex do it')\" = revise-empty ]"
check "unknown /ai command is acknowledged" \
  "[ \"\$(class_of '/ai assist')\" = unknown-command ]"
check "bare /ai is acknowledged" \
  "[ \"\$(class_of '/ai')\" = unknown-command ]"
check "/airport is not a command" \
  "[ \"\$(class_of '/airport reviews are nice')\" = feedback ]"
check "ordinary feedback is accepted" \
  "[ \"\$(class_of 'The clamp loop drops the final note, please fix it.')\" = feedback ]"
check "multi-line feedback is accepted" \
  "[ \"\$(class_of 'Two problems:\n1. The drag offset\n2. The metronome style')\" = feedback ]"
check "thanks is non-actionable" \
  "[ \"\$(class_of 'thanks')\" = non-actionable ]"
check "thank you is non-actionable" \
  "[ \"\$(class_of 'Thank you!')\" = non-actionable ]"
check "lgtm is non-actionable" \
  "[ \"\$(class_of 'LGTM')\" = non-actionable ]"
check "plus one is non-actionable" \
  "[ \"\$(class_of '+1')\" = non-actionable ]"
check "emoji reaction is non-actionable" \
  "[ \"\$(class_of '👍')\" = non-actionable ]"
check "automation marker only is non-actionable" \
  "[ \"\$(class_of '<!-- rudiment-ai-pr-preview -->')\" = non-actionable ]"
check "empty comment is non-actionable" \
  "[ \"\$(class_of '   ')\" = non-actionable ]"
check "bare question asks for clarification" \
  "[ \"\$(class_of 'Why is the metronome retriggering?')\" = clarify ]"
check "two-word comment asks for clarification" \
  "[ \"\$(class_of 'Fix this')\" = clarify ]"
check "question with a directive is feedback" \
  "[ \"\$(class_of 'Why is the metronome retriggering: clamp the index to the bar length.')\" = feedback ]"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
