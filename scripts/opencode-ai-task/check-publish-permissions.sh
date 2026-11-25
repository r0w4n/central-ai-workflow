#!/usr/bin/env bash
#
# Preflight for the repository settings that gate draft pull request creation.
#
# GitHub rejects publication when the repository's default workflow token
# permissions are read-only, and rejects pull request creation with
# "GitHub Actions is not permitted to create or approve pull requests" when
# Settings > Actions > General > "Allow GitHub Actions to create and approve
# pull requests" is disabled. Neither workflow YAML permissions nor the
# reusable workflow can enable these settings; both are manual repository
# configuration. They previously surfaced only at the publication stage, after
# the expensive implementation and validation stages. This check queries what
# GitHub's API reliably exposes and fails closed with actionable remediation
# before implementation begins.
#
# Inputs (environment):
#   REPOSITORY   owner/name of the target repository
#   GH_TOKEN     GITHUB_TOKEN of the calling workflow
#
# Exit codes:
#   0  the settings allow publication, or the API cannot verify them (warned)
#   1  a setting would reject publication; an actionable error is printed

set -euo pipefail

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"

warn() { echo "::warning::$1" >&2; }

RESPONSE="$(gh api "repos/${REPOSITORY}/actions/permissions/workflow" 2>/dev/null)" || {
  warn "Unable to read the Actions workflow permissions for ${REPOSITORY}; the API requires elevated repository access that GITHUB_TOKEN may not hold."
  warn "Verify manually before dispatching a full task: Settings > Actions > General > Workflow permissions must select 'Read and write permissions' and enable 'Allow GitHub Actions to create and approve pull requests'."
  exit 0
}

# jq's "//" alternative operator treats JSON false as falsy, so extract the
# boolean with a plain lookup ("null" when the field is absent).
DEFAULT_PERMS="$(jq -r '.default_workflow_permissions // ""' <<<"${RESPONSE}")"
CAN_CREATE_PRS="$(jq -r '.can_approve_pull_request_reviews' <<<"${RESPONSE}")"

if [ "${DEFAULT_PERMS}" = "read" ]; then
  {
    echo "::error::The default GITHUB_TOKEN permissions for ${REPOSITORY} are read-only; the publish job cannot push the task branch."
    echo "::error::Fix: repository Settings > Actions > General > Workflow permissions > select 'Read and write permissions'. YAML 'permissions:' keys cannot elevate this setting."
  } >&2
  exit 1
fi
[ -n "${DEFAULT_PERMS}" ] || {
  warn "The workflow permissions API returned no default_workflow_permissions for ${REPOSITORY}; verify the workflow permissions setting manually."
  exit 0
}

if [ "${CAN_CREATE_PRS}" = "false" ]; then
  {
    echo "::error::${REPOSITORY} does not allow GitHub Actions to create or approve pull requests; draft pull request creation would fail after implementation."
    echo "::error::Fix: repository Settings > Actions > General > Workflow permissions > enable 'Allow GitHub Actions to create and approve pull requests'. This manual repository setting cannot be enabled from workflow YAML."
  } >&2
  exit 1
fi
[ "${CAN_CREATE_PRS}" = "true" ] || {
  warn "The workflow permissions API returned no can_approve_pull_request_reviews value for ${REPOSITORY}; verify the 'Allow GitHub Actions to create and approve pull requests' setting manually."
  exit 0
}

echo "::notice::Workflow token permissions verified: GITHUB_TOKEN is read/write and Actions-created pull requests are allowed."
