#!/usr/bin/env bash
#
# Retrieve failing CI checks and their job logs for one commit, as remediation
# context for the OpenCode agent. Read-only. An API failure of the check-run
# listing is reported explicitly (non-zero exit with a ::error diagnostic) so
# a permission problem is never mistaken for a verified green or empty
# result; per-job log retrieval remains best effort when individual logs are
# unavailable.
#
# Treats all log content as untrusted data: excerpts are written to the
# context file as indented code blocks and redacted via redact.sh before use.
#
# Inputs (environment):
#   REPOSITORY   owner/name
#   HEAD_SHA     commit whose check runs are inspected (required)
#   CONTEXT_DIR  output directory; the script writes remediation-context.md
#                into it and redacts the directory in place (required)
#   MAX_JOBS     maximum failing jobs to include logs for (default 6)
#   MAX_LOG_LINES maximum log lines per job (default 250)
# Output: prints "failed_checks=<a|b|c>" and "context_file=<path>".

set -euo pipefail

. "$(dirname "$0")/lib.sh"

REPOSITORY="${REPOSITORY:?REPOSITORY is required}"
HEAD_SHA="${HEAD_SHA:?HEAD_SHA is required}"
CONTEXT_DIR="${CONTEXT_DIR:?CONTEXT_DIR is required}"
MAX_JOBS="${MAX_JOBS:-6}"
MAX_LOG_LINES="${MAX_LOG_LINES:-250}"
CONTEXT_FILE="${CONTEXT_DIR}/remediation-context.md"

fail() { echo "::error::$1" >&2; exit 1; }

mkdir -p "${CONTEXT_DIR}"
rm -f "${CONTEXT_FILE}"

CHECK_ROWS="$(gh api --paginate "repos/${REPOSITORY}/commits/${HEAD_SHA}/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.status == "completed") | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure" or .conclusion == "action_required") | [.name, .id, .details_url, .conclusion] | @tsv')" || {
  echo "::error::Could not list check runs for ${HEAD_SHA:0:12} (GET /repos/${REPOSITORY}/commits/<sha>/check-runs); failing checks cannot be verified. Grant the caller workflow 'checks: read' (job-log excerpts additionally need 'actions: read') and retry." >&2
  exit 1
}

FAILED_CHECKS="$(printf '%s\n' "${CHECK_ROWS}" | awk -F'\t' '{print $1}' | sort -u | paste -sd'|' -)"

{
  echo "# Failed CI checks"
  echo
  if [ -n "${FAILED_CHECKS}" ]; then
    printf '%s\n' "${FAILED_CHECKS}" | tr '|' '\n' | sed 's/^/- /'
  else
    echo "(the check-run listing succeeded but recorded no failing checks)"
  fi
  echo
} >"${CONTEXT_FILE}"

job_count=0
while IFS=$'\t' read -r CHECK_NAME CHECK_ID CHECK_URL CHECK_CONCLUSION; do
  [ -n "${CHECK_ID}" ] || continue
  job_count=$((job_count + 1))
  [ "${job_count}" -le "${MAX_JOBS}" ] || break
  {
    echo "## Failed check: ${CHECK_NAME} (${CHECK_CONCLUSION})"
    echo
    if [ -n "${CHECK_URL}" ]; then
      echo "Details: ${CHECK_URL}"
      echo
    fi
    if LOG="$(gh api "repos/${REPOSITORY}/actions/jobs/${CHECK_ID}/logs" 2>"${CONTEXT_DIR}/job-${CHECK_ID}-error.txt")" && [ -n "${LOG}" ]; then
      EXCERPT="$(printf '%s\n' "${LOG}" |
        grep -E -B2 -A8 '##\[(error|notice)\]|::error::|FAILED|Error:|error:' |
        head -n "${MAX_LOG_LINES}")"
      if [ -z "${EXCERPT}" ]; then
        EXCERPT="$(printf '%s\n' "${LOG}" | tail -n "${MAX_LOG_LINES}")"
      fi
      echo "Log excerpt (untrusted CI output):"
      echo
      printf '%s\n' "${EXCERPT}" | sed 's/^/    /'
      echo
    else
      if [ -s "${CONTEXT_DIR}/job-${CHECK_ID}-error.txt" ]; then
        echo "(job log excerpts could not be downloaded for this check run: $(head -c 300 "${CONTEXT_DIR}/job-${CHECK_ID}-error.txt" | tr '\n' ' '); review the linked run)"
        rm -f "${CONTEXT_DIR}/job-${CHECK_ID}-error.txt"
      else
        echo "(no job logs were produced for this check run; review the linked run)"
      fi
      echo
    fi
  } >>"${CONTEXT_FILE}"
done <<<"${CHECK_ROWS}"

# Never let untrusted CI output carry credentials into the agent context.
if ! bash "$(dirname "$0")/redact.sh" "${CONTEXT_DIR}"; then
  echo "::warning::Remediation context redaction failed; withholding untrusted log excerpts." >&2
  {
    echo "# Failed CI checks"
    echo
    echo "Log excerpts were withheld because redaction could not confirm they are secret-free."
    echo
    if [ -n "${FAILED_CHECKS}" ]; then
      printf '%s\n' "${FAILED_CHECKS}" | tr '|' '\n' | sed 's/^/- /'
    fi
  } >"${CONTEXT_FILE}"
fi

echo "failed_checks=${FAILED_CHECKS}"
echo "context_file=${CONTEXT_FILE}"
