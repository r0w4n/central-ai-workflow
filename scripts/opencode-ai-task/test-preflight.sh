#!/usr/bin/env bash
#
# Behavioural tests for scripts/opencode-ai-task/preflight.sh.
#
# Verifies the preflight against disposable Git repositories and stub tools:
# the workspace-root invariant, missing-repository failures, missing tools,
# and the rudiment-web toolchain profile requirements. No network access.
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
for tool in node npm opencode rustup rustc cargo trunk; do
  printf '#!/bin/sh\necho "%s stub"\n' "$tool" >"$stub_bin/$tool"
  chmod +x "$stub_bin/$tool"
done
# rudiment-web stubs: rustup reports the wasm target as installed by default.
printf '#!/bin/sh\n[ "$1 $2" = "target list" ] && { echo stable-x86_64-unknown-linux-gnu; echo wasm32-unknown-unknown; exit 0; }\nexit 0\n' \
  >"$stub_bin/rustup"
chmod +x "$stub_bin/rustup"

# No toolchain profile by default; GITHUB_WORKSPACE set per scenario.
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
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$repo" TOOLCHAIN_PROFILE=none \
  run_preflight pass

# Scenario 2: rudiment-web profile with all tools and the wasm target present.
scenario="pass: rudiment-web profile with wasm target and web tools"
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$repo" TOOLCHAIN_PROFILE=rudiment-web \
  run_preflight pass

# Scenario 3: workspace is not a Git repository.
scenario="fail: no Git repository at the working directory"
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$tmp/not-a-repo" TOOLCHAIN_PROFILE=none \
  run_preflight fail

# Scenario 4: the Git root is deeper than the working directory.
scenario="fail: Git root does not resolve to GITHUB_WORKSPACE"
nested="$tmp/outer/inner"
mkdir -p "$nested/outer2"
git -C "$nested/outer2" init -q
git -C "$nested/outer2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$nested" TOOLCHAIN_PROFILE=none \
  run_preflight fail

# Scenario 5: a required tool is missing.
scenario="fail: required tool opencode is missing"
isolated_bin="$tmp/isolated-bin"
mkdir -p "$isolated_bin"
for tool in node npm; do
  cp "$stub_bin/$tool" "$isolated_bin/$tool"
done
PATH="$isolated_bin:/usr/bin:/bin" GITHUB_WORKSPACE="$repo" TOOLCHAIN_PROFILE=none \
  run_preflight fail

# Scenario 6: rudiment-web profile without the wasm target installed.
scenario="fail: rudiment-web profile without the wasm32 target"
no_wasm_bin="$tmp/no-wasm-bin"
mkdir -p "$no_wasm_bin"
for tool in node npm opencode rustup rustc cargo trunk; do
  cp "$stub_bin/$tool" "$no_wasm_bin/$tool"
done
printf '#!/bin/sh\n[ "$1 $2" = "target list" ] && { echo stable-x86_64-unknown-linux-gnu; exit 0; }\nexit 0\n' \
  >"$no_wasm_bin/rustup"
chmod +x "$no_wasm_bin/rustup"
PATH="$no_wasm_bin:$PATH" GITHUB_WORKSPACE="$repo" TOOLCHAIN_PROFILE=rudiment-web \
  run_preflight fail

# Scenario 7: unsupported profile fails closed.
scenario="fail: unsupported toolchain profile"
PATH="$stub_bin:$PATH" GITHUB_WORKSPACE="$repo" TOOLCHAIN_PROFILE=made-up \
  run_preflight fail

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
