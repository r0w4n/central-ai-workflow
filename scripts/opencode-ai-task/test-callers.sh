#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

for caller in "$root/examples/generic-opencode-ai-task.yml" "$root/examples/rudiment-opencode-ai-task.yml"; do
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
  if [ "$(grep -c '^  ai-task:' "$caller")" -eq 1 ] && [ "$(wc -l <"$caller")" -lt 45 ]; then
    ok "$name remains a lightweight one-job caller"
  else
    ko "$name remains a lightweight one-job caller"
  fi
done

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
