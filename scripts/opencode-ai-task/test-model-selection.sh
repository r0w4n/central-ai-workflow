#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
selector="$here/select-model.sh"
config="$root/config/models.conf"
tmp="$(mktemp -d /tmp/model-selection.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

run_selection() {
  SPEC_FILE="$1" MODEL_CONFIG="${2:-$config}" bash "$selector" >"$tmp/out" 2>"$tmp/err"
}

echo 'ordinary issue body' >"$tmp/default.md"
if run_selection "$tmp/default.md" && grep -qx 'complexity=medium' "$tmp/out" && grep -qx 'model=opencode-go/glm-5.3-flash' "$tmp/out"; then
  ok "missing metadata uses the documented medium default"
else
  ko "missing metadata uses the documented medium default"
fi

for complexity in simple medium complex; do
  printf '<!-- ai-task-config\ncomplexity: %s\n-->\n' "$complexity" >"$tmp/$complexity.md"
  if run_selection "$tmp/$complexity.md" && grep -qx "complexity=$complexity" "$tmp/out"; then
    ok "$complexity complexity is accepted"
  else
    ko "$complexity complexity is accepted"
  fi
done

cat >"$tmp/override.md" <<'EOF'
<!-- ai-task-config
complexity: complex
model: opencode-go/glm-5.3-flash
-->
EOF
if run_selection "$tmp/override.md" && grep -qx 'model=opencode-go/glm-5.3-flash' "$tmp/out"; then
  ok "approved explicit model override is accepted"
else
  ko "approved explicit model override is accepted"
fi

cat >"$tmp/rejected.md" <<'EOF'
<!-- ai-task-config
complexity: medium
model: attacker/unknown
-->
EOF
if ! run_selection "$tmp/rejected.md" && grep -q 'is not approved' "$tmp/err"; then
  ok "unsupported explicit model is rejected"
else
  ko "unsupported explicit model is rejected"
fi

printf '<!-- ai-task-config\ncomplexity: enormous\n-->\n' >"$tmp/invalid.md"
if ! run_selection "$tmp/invalid.md" && grep -q 'unsupported complexity' "$tmp/err"; then
  ok "invalid complexity is rejected"
else
  ko "invalid complexity is rejected"
fi

printf '<!-- ai-task-config\ncomplexity: medium\n' >"$tmp/unclosed.md"
if ! run_selection "$tmp/unclosed.md" && grep -q 'not closed' "$tmp/err"; then
  ok "unclosed metadata block is rejected"
else
  ko "unclosed metadata block is rejected"
fi

cat >"$tmp/bad.conf" <<'EOF'
default_complexity=medium
simple=unapproved/model
medium=opencode-go/glm-5.3-flash
complex=opencode-go/glm-5.3-flash
allowed_model=opencode-go/glm-5.3-flash
EOF
printf '<!-- ai-task-config\ncomplexity: simple\n-->\n' >"$tmp/simple.md"
if ! run_selection "$tmp/simple.md" "$tmp/bad.conf" && grep -q 'not in the approved allowlist' "$tmp/err"; then
  ok "invalid central mapping fails closed"
else
  ko "invalid central mapping fails closed"
fi

cat >"$tmp/injection.md" <<'EOF'
<!-- ai-task-config
complexity: medium; touch /tmp/should-not-exist
-->
EOF
if ! run_selection "$tmp/injection.md" && [ ! -e /tmp/should-not-exist ]; then
  ok "metadata is parsed as data and never executed"
else
  ko "metadata is parsed as data and never executed"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
