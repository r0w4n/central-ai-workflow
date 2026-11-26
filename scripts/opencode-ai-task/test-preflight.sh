#!/usr/bin/env bash
#
# Behavioural tests for scripts/opencode-ai-task/preflight.sh.
#
# Verifies the preflight against disposable Git repositories and stub tools:
# the workspace-root invariant, missing-repository failures, and missing tools.
# Project-specific tool verification belongs to the consumer setup action.
# Usage: bash scripts/opencode-ai-task/test-preflight.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preflight="$here/preflight.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp="$(mktemp -d /tmp/opencode-preflight.XXXXXX)"
# Resolve macOS /tmp symlinks so GITHUB_WORKSPACE and `git rev-parse
# --show-toplevel` compare byte-for-byte equal.
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
for tool in node npm opencode; do
  printf '#!/bin/sh\necho "%s stub"\n' "$tool" >"$stub_bin/$tool"
  chmod +x "$stub_bin/$tool"
done

run_preflight() { # $1 = expected outcome ("pass" | "fail")
  local expected="$1" out rc
  out="$(bash "$preflight" 2>&1)" && rc=0 || rc=$?
  if [ "$expected" = "pass" ] && [ "$rc" -eq 0 ]; then
    ok "$scenario"
  elif [ "$expected" = "fail" ] && [ "$rc" -ne 0 ]; then
    ok "$scenario"
  else
    ko "$scenario (expected $expected, rc=$rc): $out"
  fi
}

# Scenario 1: workspace is the Git repository root.
scenario="pass: GITHUB_WORKSPACE is the Git repository root"
repo="$tmp/root"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$repo" \
  run_preflight pass

# Scenario 2: workspace is not a Git repository.
scenario="fail: no Git repository at the working directory"
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$tmp/not-a-repo" \
  run_preflight fail

# Scenario 3: the Git root is deeper than the working directory.
scenario="fail: Git root does not resolve to GITHUB_WORKSPACE"
nested="$tmp/outer/inner"
mkdir -p "$nested/outer2"
git -C "$nested/outer2" init -q
git -C "$nested/outer2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$nested" \
  run_preflight fail

# Scenario 4: a required central tool is missing.
scenario="fail: required tool opencode is missing"
isolated_bin="$tmp/isolated-bin"
mkdir -p "$isolated_bin"
for tool in node npm; do
  cp "$stub_bin/$tool" "$isolated_bin/$tool"
done
PATH="$isolated_bin:/usr/bin:/bin" GITHUB_WORKSPACE="$repo" \
  run_preflight fail

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
