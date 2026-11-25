#!/usr/bin/env bash
# Prove that the separately checked-out central scripts match the immutable
# revision used by the reusable workflow invocation.

set -euo pipefail

AUTOMATION_REPO="${AUTOMATION_REPO:?AUTOMATION_REPO is required}"
AUTOMATION_SHA="${AUTOMATION_SHA:?AUTOMATION_SHA is required}"
WORKFLOW_REF="${WORKFLOW_REF:?WORKFLOW_REF is required}"

fail() { echo "::error::$1" >&2; exit 1; }

[[ "${AUTOMATION_SHA}" =~ ^[0-9a-f]{40}$ ]] ||
  fail "automation_ref must be a full lowercase 40-character commit SHA"

actual="$(git -C "${AUTOMATION_REPO}" rev-parse HEAD)"
[ "${actual}" = "${AUTOMATION_SHA}" ] ||
  fail "trusted scripts resolved to ${actual}, expected ${AUTOMATION_SHA}"

case "${WORKFLOW_REF}" in
  *@"${AUTOMATION_SHA}") ;;
  *) fail "reusable workflow ref and automation_ref differ (${WORKFLOW_REF})" ;;
esac

echo "Trusted automation checkout verified at ${AUTOMATION_SHA}."
