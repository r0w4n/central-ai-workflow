#!/usr/bin/env bash
#
# Publication sequence for both OpenCode task modes. Initial implementations
# push a new branch and create a pull request. Revisions update the existing
# pull-request branch only when its remote head still equals the authorised
# base SHA; they never create a second pull request.
#
# Runs in the publish job from a TRUSTED checkout. GitHub credentials are
# supplied via GIT_ASKPASS only; the token never appears in a remote URL or
# Git configuration. If pull request creation fails after the push, the
# pushed branch is deleted again so no orphaned branch remains.
#
# Inputs (environment):
#   PUBLISH_WORK      working clone with the validated changes applied
#   ARTIFACT_DIR      downloaded VALIDATED artifact (meta.json, patches/,
#                     pr-summary.md, issue-title.txt)
#   BRANCH, ISSUE_NUMBER, BASE_SHA, DEFAULT_BRANCH
#   PR_DRAFT          "false" opens the pull request ready for review
#                     (default: draft)
#   USING_APP_TOKEN   "true" when GH_TOKEN is a GitHub App installation token;
#                     adjusts the automation notes in the pull request body
#   GH_TOKEN          write token (via askpass; not stored anywhere)
#   RUN_URL           optional workflow run link for the PR body
#   NOTIFY_GH         set to 0 in tests to skip calls that need gh
# Outputs:
#   Prints the created PR URL as "PR_URL=<url>" on success.
# Exits 1 (fail closed) before pushing whenever anything is invalid.

set -euo pipefail

. "$(dirname "$0")/lib.sh"

PUBLISH_WORK="${PUBLISH_WORK:?PUBLISH_WORK is required}"
ARTIFACT_DIR="${ARTIFACT_DIR:?ARTIFACT_DIR is required}"
BRANCH="${BRANCH:?BRANCH is required}"
ISSUE_NUMBER="${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
BASE_SHA="${BASE_SHA:?BASE_SHA is required}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
# Testable override: the complete remote URL. Defaults to the real GitHub.
REMOTE_URL="${REMOTE_URL:-https://github.com/${REPOSITORY}.git}"
RUN_URL="${RUN_URL:-}"
PR_DRAFT="${PR_DRAFT:-true}"
USING_APP_TOKEN="${USING_APP_TOKEN:-false}"
PR_BODY_FILE="${PR_BODY_FILE:-${RUNNER_TEMP:-/tmp}/opencode-pr-body.md}"
TASK_MODE="${TASK_MODE:-implementation}"
PR_NUMBER="${PR_NUMBER:-0}"
COMMENT_ID="${COMMENT_ID:-0}"
PUBLICATION_RESULT_FILE="${PUBLICATION_RESULT_FILE:-${RUNNER_TEMP:-/tmp}/opencode-publication-result}"

fail() { echo "::error::$1" >&2; exit 1; }

require_numeric "${ISSUE_NUMBER}" || fail "issue number is not numeric"
case "${TASK_MODE}" in implementation|revision|remediation) ;; *) fail "TASK_MODE must be implementation, revision or remediation" ;; esac
require_numeric "${PR_NUMBER}" || fail "PR_NUMBER must be numeric"
require_numeric "${COMMENT_ID}" || fail "COMMENT_ID must be numeric"
if [ "${TASK_MODE}" != implementation ]; then
  [ "${PR_NUMBER}" -gt 0 ] || fail "revision PR number is missing"
  if [ "${TASK_MODE}" = revision ]; then
    [ "${COMMENT_ID}" -gt 0 ] || fail "revision comment ID is missing"
  fi
fi
case "${PR_DRAFT}" in true|false) ;; *) fail "PR_DRAFT must be true or false" ;; esac
case "${USING_APP_TOKEN}" in true|false) ;; *) fail "USING_APP_TOKEN must be true or false" ;; esac

# --- Validate the artifact metadata BEFORE any push ---------------------------
META="${ARTIFACT_DIR}/meta.json"
[ -f "${META}" ] || fail "meta.json is missing from the validated artifact"
META_ISSUE="$(json_string_value "${META}" issue_number)"
META_BRANCH="$(json_string_value "${META}" branch)"
META_BASE="$(json_string_value "${META}" base_sha)"
META_MODEL="$(json_string_value "${META}" model)"
META_COMPLEXITY="$(json_string_value "${META}" complexity)"
META_AUTOMATION_SHA="$(json_string_value "${META}" automation_sha)"
META_TASK_MODE="$(json_string_value "${META}" task_mode)"
META_PR_NUMBER="$(json_number_value "${META}" pr_number)"
META_COMMENT_ID="$(json_number_value "${META}" comment_id)"
[ "${META_TASK_MODE}" = "${TASK_MODE}" ] || fail "artifact task mode does not match this run"
[ "${META_PR_NUMBER}" = "${PR_NUMBER}" ] || fail "artifact PR number does not match this run"
[ "${META_COMMENT_ID}" = "${COMMENT_ID}" ] || fail "artifact comment ID does not match this run"
[ "${META_ISSUE}" = "${ISSUE_NUMBER}" ] ||
  fail "artifact issue (${META_ISSUE:-<missing>}) does not match the task issue (${ISSUE_NUMBER})"
[ "${META_BRANCH}" = "${BRANCH}" ] ||
  fail "artifact branch (${META_BRANCH:-<missing>}) does not match the task branch (${BRANCH})"
[ "${META_BASE}" = "${BASE_SHA}" ] ||
  fail "artifact base does not match the pinned base revision"
require_numeric "${META_ISSUE}" || fail "artifact issue number is invalid"
[ "${META_AUTOMATION_SHA}" = "${AUTOMATION_SHA:?AUTOMATION_SHA is required}" ] ||
  fail "artifact automation version does not match the reusable workflow"
case "${META_COMPLEXITY}" in simple|medium|complex) ;; *) fail "artifact complexity is invalid" ;; esac

TITLE_FILE="${ARTIFACT_DIR}/issue-title.txt"
[ -f "${TITLE_FILE}" ] || fail "issue-title.txt is missing from the validated artifact"
ISSUE_TITLE="$(head -n 1 "${TITLE_FILE}")"
[ -n "${ISSUE_TITLE}" ] || fail "issue title in the validated artifact is empty"

SUMMARY_FILE="${ARTIFACT_DIR}/pr-summary.md"
[ -f "${SUMMARY_FILE}" ] || fail "pr-summary.md is missing from the validated artifact"
SUMMARY="$(cat "${SUMMARY_FILE}")"

# --- Build the pull request body for a new implementation ---------------------
if [ "${TASK_MODE}" = implementation ]; then
  {
  echo "<!-- central-ai-generated-pr -->"
  echo "## Summary"
  echo
  echo "${SUMMARY}"
  echo
  echo "## Automation notes"
  echo
  echo "- Created automatically by OpenCode from issue #${ISSUE_NUMBER}."
  echo "- Complexity: \`${META_COMPLEXITY}\`; model: \`${META_MODEL:-unknown}\`."
  echo "- Central automation revision: \`${META_AUTOMATION_SHA}\`."
  if [ "${PR_DRAFT}" = "true" ]; then
    echo "- Draft pull request: nothing is merged, deployed or pushed to \`${DEFAULT_BRANCH}\` until you review and approve it."
  else
    echo "- Nothing is merged, deployed or pushed to \`${DEFAULT_BRANCH}\` until you review and approve it."
  fi
  if [ "${USING_APP_TOKEN}" = "true" ]; then
    echo "- CI checks for this PR start automatically; the pull request was created with a GitHub App token."
  else
    echo "- CI checks for this PR were created by \`GITHUB_TOKEN\` and are held for approval; approve the workflow runs from the pull request page to start the repository checks."
  fi
  if [ -n "${RUN_URL}" ]; then
    echo "- Workflow run: ${RUN_URL}"
  fi
  echo
  echo "Closes #${ISSUE_NUMBER}"
  } >"${PR_BODY_FILE}"
fi

# --- Git hygiene before anything authenticated --------------------------------
git -C "${PUBLISH_WORK}" config credential.helper ""
NO_HOOKS_DIR="${PUBLISH_WORK}-no-hooks"
mkdir -p "${NO_HOOKS_DIR}"
git -C "${PUBLISH_WORK}" config core.hooksPath "${NO_HOOKS_DIR}"

# --- Credentials via askpass only ---------------------------------------------
ASKPASS="${RUNNER_TEMP:-/tmp}/git-askpass.$$.sh"
cat >"${ASKPASS}" <<'ASKPASS'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "x-access-token" ;;
  *)         printf '%s\n' "${GH_TOKEN}" ;;
esac
ASKPASS
chmod 700 "${ASKPASS}"
export GIT_ASKPASS="${ASKPASS}"
export GIT_TERMINAL_PROMPT=0

git -C "${PUBLISH_WORK}" remote add publish-origin "${REMOTE_URL}" 2>/dev/null ||
  git -C "${PUBLISH_WORK}" remote set-url publish-origin "${REMOTE_URL}"
cleanup() {
  git -C "${PUBLISH_WORK}" remote remove publish-origin 2>/dev/null || true
  rm -f "${ASKPASS}"
}
trap cleanup EXIT

# --- Push only the approved task branch --------------------------------------
if [ "${TASK_MODE}" != implementation ]; then
  # Revalidate the mutable PR state immediately before the authenticated push.
  PR_DATA="$(gh api "repos/${REPOSITORY}/pulls/${PR_NUMBER}")" || fail "could not re-read pull request #${PR_NUMBER}"
  [ "$(jq -r '.state // ""' <<<"${PR_DATA}")" = open ] || fail "pull request is no longer open"
  [ "$(jq -r '.merged // false' <<<"${PR_DATA}")" = false ] || fail "pull request is already merged"
  [ "$(jq -r '.base.ref // ""' <<<"${PR_DATA}")" = "${DEFAULT_BRANCH}" ] || fail "pull request base changed"
  [ "$(jq -r '.head.repo.full_name // ""' <<<"${PR_DATA}")" = "${REPOSITORY}" ] || fail "pull request head repository changed"
  [ "$(jq -r '.head.ref // ""' <<<"${PR_DATA}")" = "${BRANCH}" ] || fail "pull request head branch changed"
  [ "$(jq -r '.head.sha // ""' <<<"${PR_DATA}")" = "${BASE_SHA}" ] || fail "pull request head changed while the revision was running"

  REMOTE_HEAD="$(git -C "${PUBLISH_WORK}" ls-remote publish-origin "refs/heads/${BRANCH}" | awk 'NR == 1 {print $1}')"
  [ "${REMOTE_HEAD}" = "${BASE_SHA}" ] || fail "remote branch head changed while the revision was running"
  git -C "${PUBLISH_WORK}" merge-base --is-ancestor "${BASE_SHA}" HEAD || fail "revision does not preserve existing PR history"

  # The exact lease makes the push atomic with the preceding checks. The new
  # head is a descendant of BASE_SHA, so this cannot discard approved history.
  git -C "${PUBLISH_WORK}" push --no-verify \
    "--force-with-lease=refs/heads/${BRANCH}:${BASE_SHA}" \
    publish-origin "HEAD:refs/heads/${BRANCH}" ||
    fail "revision push was rejected because the PR branch changed"
else
  git -C "${PUBLISH_WORK}" push --no-verify publish-origin "${BRANCH}:${BRANCH}" ||
    fail "pushing ${BRANCH} failed"
fi

# --- Revisions stop here: update the existing PR, never create another --------
if [ "${TASK_MODE}" != implementation ]; then
  NEW_HEAD="$(git -C "${PUBLISH_WORK}" rev-parse HEAD)"
  {
    echo "commit_sha=${NEW_HEAD}"
    echo "pr_url=https://github.com/${REPOSITORY}/pull/${PR_NUMBER}"
  } >"${PUBLICATION_RESULT_FILE}"
  cleanup
  echo "PR_URL=https://github.com/${REPOSITORY}/pull/${PR_NUMBER}"
  echo "COMMIT_SHA=${NEW_HEAD}"
  echo "::notice::Revision pushed to existing pull request #${PR_NUMBER}."
  exit 0
fi

# --- Create a new pull request; clean up its branch if creation fails ---------
DRAFT_FLAG=(--draft)
[ "${PR_DRAFT}" = "false" ] && DRAFT_FLAG=()
if ! gh pr create ${DRAFT_FLAG[@]+"${DRAFT_FLAG[@]}"} \
    --repo "${REPOSITORY}" \
    --base "${DEFAULT_BRANCH}" \
    --head "${BRANCH}" \
    --title "ai: issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}" \
    --body-file "${PR_BODY_FILE}"; then
  echo "::error::Pull request creation failed after the branch push."
  if git -C "${PUBLISH_WORK}" push --no-verify publish-origin --delete "${BRANCH}" >/dev/null 2>&1; then
    echo "::error::The pushed branch ${BRANCH} was deleted again so no orphaned branch remains."
    echo "::error::The validated implementation is retained as the 'opencode-validated' artifact of this run; fix the cause and rerun the task (dedup will then allow a fresh branch)."
  else
    echo "::error::The branch ${BRANCH} could not be deleted automatically. Delete it manually: git push origin --delete ${BRANCH}"
  fi
  exit 1
fi

cleanup

PR_URL="$(gh pr view "${BRANCH}" --repo "${REPOSITORY}" --json url --jq '.url')"
{
  echo "commit_sha=$(git -C "${PUBLISH_WORK}" rev-parse HEAD)"
  echo "pr_url=${PR_URL}"
} >"${PUBLICATION_RESULT_FILE}"
echo "PR_URL=${PR_URL}"
if [ "${PR_DRAFT}" = "true" ]; then
  echo "::notice::Draft pull request created: ${PR_URL}"
else
  echo "::notice::Pull request created ready for review: ${PR_URL}"
fi
if [ "${USING_APP_TOKEN}" != "true" ]; then
  echo "::notice::Its CI workflow runs are held for approval; approve them from the pull request page to start the repository checks."
fi

