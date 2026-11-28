#!/usr/bin/env bash
#
# Behavioural tests for fetch-remediation-context.sh: failing-check listing,
# size-capped log excerpts, graceful degradation without log access, and
# untrusted-output handling.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

SHA=1111111111111111111111111111111111111111
CHECKS='{"check_runs":[
  {"name":"Quality assurance / code-and-unit","id":7001,"status":"completed","conclusion":"failure","details_url":"https://example.invalid/7001"},
  {"name":"CodeQL (rust)","id":7002,"status":"completed","conclusion":"failure","details_url":"https://example.invalid/7002"},
  {"name":"fast","id":7003,"status":"completed","conclusion":"success","details_url":""}
]}'
LOG1="$(printf 'step one ok\ngood line\n##[error]Process completed with exit code 1\nFAIL drag_test\nstack line 1\nstack line 2\nfinal summary')"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<FAKEGH
#!/usr/bin/env bash
case "\$*" in
  *"check-runs"*) echo '${CHECKS}' | jq -r '.check_runs[] | select(.status == "completed") | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure" or .conclusion == "action_required") | [.name, (.id | tostring), .details_url, .conclusion] | @tsv' ;;
  *"actions/jobs/7001/logs"*) printf '%s\n' '${LOG1}' ;;
  *"actions/jobs/7002/logs"*) echo 'HTTP 403: log access denied' >&2; exit 1 ;;
  *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
FAKEGH
chmod +x "$tmp/bin/gh"

OUT="$(PATH="$tmp/bin:$PATH" REPOSITORY=r0w4n/example HEAD_SHA="${SHA}" CONTEXT_DIR="$tmp/ctx" \
  bash "${here}/fetch-remediation-context.sh")"
check "both failing checks are listed" "grep -q '^failed_checks=CodeQL .rust.|Quality assurance / code-and-unit$' <<<\"$OUT\""
check "the passing check is not listed" "! grep -q 'failed_checks=.*fast' <<<\"$OUT\""
check "log excerpts are indented as untrusted data" "grep -q '^    ##\[error\]' '$tmp/ctx/remediation-context.md'"
check "error context is captured" "grep -q 'FAIL drag_test' '$tmp/ctx/remediation-context.md'"
check "unavailable job logs degrade gracefully" "grep -q 'log excerpts unavailable' '$tmp/ctx/remediation-context.md'"
check "each failed check has a section" "[ \"\$(grep -c '^## Failed check:' '$tmp/ctx/remediation-context.md')\" = 2 ]"
check "details links are included" "grep -q 'https://example.invalid/7001' '$tmp/ctx/remediation-context.md'"

# A check-run listing API failure must not fabricate failures: it aborts with
# an explicit diagnostic instead of degrading to an empty list.
cat >"$tmp/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo 'HTTP 403' >&2
exit 1
FAKEGH
chmod +x "$tmp/bin/gh"
if OUT="$(PATH="$tmp/bin:$PATH" REPOSITORY=r0w4n/example HEAD_SHA="${SHA}" CONTEXT_DIR="$tmp/ctx2" \
  bash "${here}/fetch-remediation-context.sh" 2>"$tmp/err.txt")"; then
  ko "check-run API failures abort the context retrieval"
else
  ok "check-run API failures abort the context retrieval"
fi
check "the API error names the missing checks scope" "grep -q 'checks: read' '$tmp/err.txt'"
check "the API error is a workflow error annotation" "grep -q '::error::' '$tmp/err.txt'"
check "no fabricated context is written" "[ ! -f '$tmp/ctx2/remediation-context.md' ]"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
