#!/usr/bin/env bash
#
# Preflight verification before the implementation agent starts.
#
# Runs in the read-only implementation job from the trusted script snapshot,
# before any expensive model work. It fails closed when the environment would
# make the run unreliable: a working directory outside the checked-out
# repository, or a missing required tool or toolchain component.
#
# Inputs (environment):
#   GITHUB_WORKSPACE   runner workspace containing the checked-out repository
# Outputs: diagnostic logs only. Exits 1 on any missing prerequisite.

set -euo pipefail

fail() { echo "::error::$1" >&2; exit 1; }

WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
cd "${WORKSPACE}"

# --- Working directory and repository discovery -------------------------------
# The target repository is checked out at the runner workspace root, so Git
# commands, repository discovery, AGENTS.md lookups, and build commands all
# resolve to the same tree regardless of each tool's inherited directory.
echo "::group::Working directory and Git checkout"
echo "pwd: $(pwd)"
echo "GITHUB_WORKSPACE: ${WORKSPACE}"
top="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  fail "no Git repository found at the agent working directory ${WORKSPACE}"
[ "${top}" = "${WORKSPACE}" ] ||
  fail "git rev-parse --show-toplevel resolved to ${top}, not \$GITHUB_WORKSPACE (${WORKSPACE})"
echo "git toplevel: ${top}"
head_sha="$(git rev-parse --verify HEAD)" ||
  fail "the checkout has no HEAD commit"
echo "HEAD: ${head_sha}"
echo "git version: $(git --version)"
echo "::endgroup::"

# --- Required tools ------------------------------------------------------------
echo "::group::Required tool versions"
require() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "required tool '$1' is not available before implementation"
}
for tool in git node npm opencode; do
  require "${tool}"
done
node --version
npm --version
opencode --version
echo "::endgroup::"

echo "::notice::Preflight verified: the agent working directory is the Git repository root and all required tools are available."
