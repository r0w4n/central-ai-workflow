#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GITHUB_WORKSPACE="$tmp/target" RUNNER_TEMP="$tmp/runner"
mkdir -p "$GITHUB_WORKSPACE/.github" "$RUNNER_TEMP"
script="$here/consumer-setup-actions.sh"
pass=0
fail=0
check() {
  local label="$1"
  shift
  if "$@"; then echo "PASS: $label"; pass=$((pass + 1));
  else echo "FAIL: $label"; fail=$((fail + 1)); fi
}

caller_actions="$GITHUB_WORKSPACE/.consumer-setup/.github/actions"
mkdir -p "$caller_actions/setup-ai-task" "$caller_actions/setup-rudiment"
echo reviewed >"$caller_actions/setup-ai-task/action.yml"
echo nested >"$caller_actions/setup-rudiment/action.yml"
bash "$script" stage
check "older PR head can use the caller's reviewed setup action" \
  test -f "$GITHUB_WORKSPACE/.github/actions/setup-ai-task/action.yml"
check "nested local actions resolve under the ordinary workspace path" \
  test -f "$GITHUB_WORKSPACE/.github/actions/setup-rudiment/action.yml"
bash "$script" restore
check "setup checkout is removed before the agent" \
  test ! -e "$GITHUB_WORKSPACE/.consumer-setup"
check "older PR head remains without newly staged actions" \
  test ! -e "$GITHUB_WORKSPACE/.github/actions"

mkdir -p "$caller_actions/setup-ai-task" "$GITHUB_WORKSPACE/.github/actions/setup-ai-task"
echo reviewed >"$caller_actions/setup-ai-task/action.yml"
echo older >"$GITHUB_WORKSPACE/.github/actions/setup-ai-task/action.yml"
bash "$script" stage
check "caller action replaces an older PR head action during setup" \
  test "$(cat "$GITHUB_WORKSPACE/.github/actions/setup-ai-task/action.yml")" = reviewed
bash "$script" restore
check "original PR head action is restored byte for byte" \
  test "$(cat "$GITHUB_WORKSPACE/.github/actions/setup-ai-task/action.yml")" = older

mkdir -p "$caller_actions"
if bash "$script" stage >"$tmp/out" 2>"$tmp/err"; then
  echo "FAIL: missing caller setup action fails closed"; fail=$((fail + 1))
else
  check "missing caller setup action fails closed without replacing PR files" \
    test "$(cat "$GITHUB_WORKSPACE/.github/actions/setup-ai-task/action.yml")" = older
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
