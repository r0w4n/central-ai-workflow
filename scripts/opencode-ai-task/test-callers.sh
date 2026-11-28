#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

for caller in "$root/examples/generic-opencode-ai-task.yml" "$root/examples/custom-environment-opencode-ai-task.yml"; do
  name="$(basename "$caller")"
  if grep -q 'types: \[labeled\]' "$caller" && grep -q "github.event.label.name == 'ai-task'" "$caller"; then
    ok "$name retains issues:labeled and ai-task trigger"
  else
    ko "$name retains issues:labeled and ai-task trigger"
  fi
  if grep -q 'workflow_dispatch:' "$caller" && grep -q 'dry_run:' "$caller"; then
    ok "$name retains manual dry-run dispatch"
  else
    ko "$name retains manual dry-run dispatch"
  fi
  if grep -q 'issue_comment:' "$caller" && grep -q "github.event_name == 'issue_comment' && github.event.issue.pull_request" "$caller"; then
    ok "$name routes PR comments to the central classifier"
  else
    ko "$name routes PR comments to the central classifier"
  fi
  if grep -q 'actions: write' "$caller"; then
    ok "$name grants actions: write for retry dispatch and log retrieval"
  else
    ko "$name grants actions: write for retry dispatch and log retrieval"
  fi
  if grep -q 'remediation_event:' "$caller" && grep -q 'remediation_max_attempts:' "$caller"; then
    ok "$name forwards remediation inputs"
  else
    ko "$name forwards remediation inputs"
  fi
  if grep -q 'caller_workflow:' "$caller"; then
    ok "$name enables bounded remediation retries"
  else
    ko "$name enables bounded remediation retries"
  fi
  if grep -q 'uses: r0w4n/central-ai-workflow/.github/workflows/opencode-ai-task.yml@' "$caller"; then
    ok "$name calls the central reusable workflow"
  else
    ko "$name calls the central reusable workflow"
  fi
  if grep -q 'OPENCODE_GO_API_KEY: \${{ secrets.OPENCODE_GO_API_KEY }}' "$caller"; then
    ok "$name propagates only the required model secret"
  else
    ko "$name propagates only the required model secret"
  fi
  if grep -q 'contents: write' "$caller" && grep -q 'issues: write' "$caller" && grep -q 'pull-requests: write' "$caller"; then
    ok "$name declares the permissions the called jobs narrow"
  else
    ko "$name declares the permissions the called jobs narrow"
  fi
  if [ "$(grep -c '^  ai-task:' "$caller")" -eq 1 ] && [ "$(wc -l <"$caller")" -lt 100 ]; then
    ok "$name remains a lightweight one-job caller"
  else
    ko "$name remains a lightweight one-job caller"
  fi
  if grep -q 'APP_ID: \${{ secrets.APP_ID }}' "$caller" && grep -q 'APP_PRIVATE_KEY: \${{ secrets.APP_PRIVATE_KEY }}' "$caller"; then
    ok "$name supplies App credentials required for revision publication"
  else
    ko "$name supplies App credentials required for revision publication"
  fi
done

if grep -q 'setup: true' \
  "$root/examples/custom-environment-opencode-ai-task.yml" &&
  ! grep -q '^[[:space:]]*setup: true' "$root/examples/generic-opencode-ai-task.yml"; then
  ok "consumer environment setup is optional"
else
  ko "consumer environment setup is optional"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
