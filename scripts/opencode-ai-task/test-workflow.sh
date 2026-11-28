#!/usr/bin/env bash
#
# Static security and regression checks for the OpenCode AI task workflow.
#
# Complements the behavioural tests by asserting invariants of the committed
# workflow file and gate scripts: staged isolation, credential isolation,
# trusted-script ordering, artifact-only data flow, authorisation gating,
# draft-only pull requests and the Markdown code-fence regression.
# Usage: bash scripts/opencode-ai-task/test-workflow.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/opencode-ai-task.yml"

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }

assert_in() { # $1 = file, $2 = scenario, $3 = pattern
  if grep -qE -- "$3" "$1"; then ok "$2"; else ko "$2 (missing: $3)"; fi
}

assert_not_in() { # $1 = file, $2 = scenario, $3 = pattern
  if grep -qE -- "$3" "$1"; then ko "$2 (found: $3)"; else ok "$2"; fi
}

job_block() { # echoes "start end" lines of the named job
  local name="$1" start end total
  start="$(grep -nE "^  ${name}:" "$workflow" | head -1 | cut -d: -f1)"
  if [ -z "$start" ]; then echo "0 0"; return; fi
  total="$(wc -l <"$workflow")"
  end="$(awk -v s="$((start + 1))" 'NR >= s && /^  [a-z]+:/{print NR; exit}' "$workflow")"
  [ -n "$end" ] || end="$total"
  echo "$start $end"
}

step_range() { # echoes "start end" of the named step inside the workflow
  local name="$1" start end total
  start="$(grep -nE -- "^      - name: ${name}\$" "$workflow" | head -1 | cut -d: -f1)"
  if [ -z "$start" ]; then echo "0 0"; return; fi
  total="$(wc -l <"$workflow")"
  end="$(awk -v s="$((start + 1))" 'NR >= s && /^      - name:/{print NR; exit}' "$workflow")"
  [ -n "$end" ] || end="$total"
  echo "$start $end"
}

# --- Stages exist --------------------------------------------------------------
for job in authorise implement validate publish notify; do
  job_block "$job" | grep -qv '^0 0$' && ok "stage job present: $job" \
    || ko "stage job present: $job"
done

# --- Markdown code-fence regression -------------------------------------------
# A bare code-fence line is a shell command and fails the step under set -e.
FENCE='```'
if grep -qE -- "^[[:space:]]*'${FENCE}'[[:space:]]*\$" "$workflow" \
  "$here/export-changes.sh" "$here/validate-changes.sh"; then
  ko "no bare code-fence commands (bare fence line found)"
else
  ok "no bare code-fence commands"
fi

# --- Authorisation gating ------------------------------------------------------
assert_in "$workflow" "implement job gated on authorisation output" \
  "needs\.authorise\.outputs\.proceed == 'true'"
[ "$(grep -c "needs.authorise.outputs.proceed == 'true'" "$workflow")" -ge 3 ] &&
  ok "all model-touching stages gated on authorisation" ||
  ko "all model-touching stages gated on authorisation"
assert_in "$workflow" "issue author gate present" \
  "github\.event\.issue\.user\.login"
assert_in "$workflow" "label application sender gate present" \
  "github\.event\.sender\.login"
[ "$(grep -c "authorise.sh" "$workflow")" -ge 2 ] &&
  ok "authorisation gate script used in authorise and implement jobs" ||
  ko "authorisation gate script used in authorise and implement jobs"
assert_in "$workflow" "dry-run dispatch mode preserved" \
  "inputs\.dry_run"
assert_in "$workflow" "consumer setup interface is declared" \
  "^[[:space:]]+setup:"
assert_in "$workflow" "consumer setup is explicitly opt-in" \
  "if: inputs\.setup"
assert_in "$workflow" "consumer setup is fetched from the immutable caller revision" \
  'ref: \$\{\{ github.sha \}\}'
assert_in "$workflow" "consumer setup checkout stays separate from the agent workspace" \
  'path: \.consumer-setup'
assert_in "$workflow" "consumer setup actions are staged by a trusted script" \
  'consumer-setup-actions.sh" stage'
assert_in "$workflow" "consumer setup actions are restored even after setup failure" \
  'consumer-setup-actions.sh" restore'
assert_in "$workflow" "revision mode is an explicit reusable interface" \
  "task_mode:"
assert_in "$workflow" "PR and immutable comment inputs are declared" \
  "comment_id:"
assert_in "$workflow" "all PR comments reach the classifier gate" \
  "github\.event_name == 'issue_comment' &&"
assert_in "$workflow" "revision authorisation stays script-side" \
  'TRUSTED_SCRIPTS\}/revision-gate\.sh'
assert_in "$workflow" "silently ignored feedback is never answered" \
  '"\$\{ACK\}" = public \]'
assert_in "$workflow" "remediation mode is gated to router events" \
  "github\.event_name == 'workflow_run'"
assert_in "$workflow" "remediation episode transitions run from the decision script" \
  'remediation-decision\.sh'
assert_not_in "$workflow" "close-episode handling is not re-implemented inline in YAML" \
  'PROCEED." != true . && .\$\{ACTION\}. = close-episode'
assert_in "$workflow" "comments cannot select the model" \
  'SPEC_FILE="\$\{ISSUE_SPEC_FILE\}"'
assert_in "$workflow" "per-PR concurrency never cancels queued feedback" \
  "cancel-in-progress: false"

# --- Job permissions -----------------------------------------------------------
block_contains() { # $1 = job name, $2 = pattern; reads the whole block
                   # first to avoid the sed|grep -q SIGPIPE race under
                   # pipefail.
  local range block
  range="$(job_block "$1")"
  block="$(sed -n "${range%% *},${range##* }p" "$workflow")"
  grep -q "$2" <<<"$block"
}
tb="$(job_block authorise)"; t_start=${tb%% *}; t_end=${tb##* }
if block_contains authorise "contents: write"; then
  ko "authorise job has no write permissions"
else
  ok "authorise job has no write permissions"
fi
if block_contains authorise "pull-requests: write" && block_contains authorise "issues: read"; then
  ok "trusted authorise job can acknowledge PR revisions"
else
  ko "trusted authorise job can acknowledge PR revisions"
fi
pb="$(job_block implement)"
if block_contains implement "contents: write"; then
  ko "implement job has no write permissions"
else
  ok "implement job has no write permissions"
fi
if block_contains implement "actions: read"; then
  ok "implement job can read failing-check runs and logs"
else
  ko "implement job can read failing-check runs and logs"
fi
if block_contains authorise "checks: read" && block_contains authorise "actions: read"; then
  ok "authorise job can verify failing checks through the Checks API"
else
  ko "authorise job can verify failing checks through the Checks API"
fi
if block_contains implement "checks: read"; then
  ok "implement job can recheck failing checks through the Checks API"
else
  ko "implement job can recheck failing checks through the Checks API"
fi
vb="$(job_block validate)"
if block_contains validate "contents: write|pull-requests: write"; then
  ko "validate job has write permissions"
else
  ok "validate job has write permissions"
fi
if block_contains publish "contents: write"; then
  ok "publish job holds the write permissions"
else
  ko "publish job holds the write permissions"
fi
if block_contains publish "issues: write"; then
  ok "publish job may update the trusted revision audit comment"
else
  ko "publish job may update the trusted revision audit comment"
fi
if block_contains notify "pull-requests: write" && block_contains notify "actions: write"; then
  ok "trusted notify job can update PR status and dispatch retries"
else
  ko "trusted notify job can update PR status and dispatch retries"
fi
assert_in "$workflow" "top-level permissions declare the required caller grants" \
  "^permissions:\$"
[ "$(grep -c "^  contents: write" "$workflow")" -ge 1 ] &&
  [ "$(grep -c "^  pull-requests: write" "$workflow")" -ge 1 ] &&
  [ "$(grep -c "^  issues: write" "$workflow")" -ge 1 ] &&
  [ "$(grep -c "^  checks: read" "$workflow")" -ge 1 ] &&
  ok "top-level permissions include contents, pull-requests, and issues write plus checks read" ||
  ko "top-level permissions include contents, pull-requests, and issues write plus checks read"
assert_in "$here/check-publish-permissions.sh" \
  "permission preflight explains the manual repository setting" \
  "Allow GitHub Actions to create and approve pull requests"

# --- Preflight gates before implementation ------------------------------------
assert_in "$workflow" "authorise preflights publication permissions" \
  "check-publish-permissions.sh"
assert_in "$workflow" "implementation preflights the environment from trusted scripts" \
  'TRUSTED_SCRIPTS\}/preflight\.sh'
assert_in "$here/preflight.sh" "preflight requires the Git root to be GITHUB_WORKSPACE" \
  'git rev-parse --show-toplevel resolved to'
assert_in "$here/preflight.sh" "preflight fails closed on missing tools" \
  "is not available before implementation"
ps="$(step_range "Preflight workspace and tools")"; preflight_start=${ps%% *}
ie="$(step_range "Implement the task")"; impl_start=${ie%% *}
if [ "$preflight_start" -gt 0 ] && [ "$preflight_start" -lt "$impl_start" ]; then
  ok "preflight runs before the agent starts"
else
  ko "preflight runs before the agent starts"
fi
cs="$(step_range "Check out caller setup actions")"; cs_start=${cs%% *}; cs_end=${cs##* }
st="$(step_range "Stage caller setup actions")"; st_start=${st%% *}
su="$(step_range "Set up consumer environment")"; su_start=${su%% *}
rs="$(step_range "Restore target actions and remove setup checkout")"; rs_start=${rs%% *}
if [ "$cs_start" -gt 0 ] && [ "$cs_start" -lt "$st_start" ] &&
  [ "$st_start" -lt "$su_start" ] && [ "$su_start" -lt "$rs_start" ] &&
  [ "$rs_start" -lt "$preflight_start" ]; then
  ok "reviewed setup is staged and restored before agent preflight"
else
  ko "reviewed setup is staged and restored before agent preflight"
fi
if sed -n "${cs_start},${cs_end}p" "$workflow" | grep -q 'persist-credentials: false'; then
  ok "caller setup checkout drops persisted credentials"
else
  ko "caller setup checkout drops persisted credentials"
fi

# --- Agent working directory ----------------------------------------------------
assert_in "$workflow" "target checkout is the runner workspace root" \
  'path: \.$'
assert_in "$workflow" "agent step pins the working directory to the workspace" \
  'working-directory: \$\{\{ github.workspace \}\}'
assert_in "$workflow" "implement steps cd to GITHUB_WORKSPACE explicitly" \
  'cd "\$\{GITHUB_WORKSPACE\}"'
assert_in "$workflow" "automation checkout is removed before the agent runs" \
  'rm -rf "\$\{GITHUB_WORKSPACE\}/automation"'
assert_in "$workflow" "agent logs the resolved repository root" \
  'git rev-parse --show-toplevel'

# --- Credential isolation ------------------------------------------------------
[ "$(grep -c "persist-credentials: false" "$workflow")" -ge 3 ] &&
  ok "every checkout drops persisted credentials" ||
  ko "every checkout drops persisted credentials"
[ "$(grep -c "ref: \${{ needs.authorise.outputs.base_sha }}" "$workflow")" -eq 3 ] &&
  ok "implement/validate/publish check out the pinned base revision" ||
  ko "implement/validate/publish check out the pinned base revision"

os="$(step_range "Implement the task")"; o_start=${os%% *}; o_end=${os##* }
if sed -n "${o_start},${o_end}p" "$workflow" | grep -qE "GH_TOKEN|github\.token|GITHUB_TOKEN"; then
  ko "OpenCode step receives no GitHub token"
else
  ok "OpenCode step receives no GitHub token"
fi
if [ "$(grep -c -- "OPENCODE_API_KEY:" "$workflow")" -le 2 ]; then
  ok "API key referenced only in the implement and diagnostics steps"
else
  ko "API key referenced only in the implement and diagnostics steps"
fi

# --- Trusted script ordering ---------------------------------------------------
ss="$(step_range "Verify and snapshot trusted automation")"; s_start=${ss%% *}; s_end=${ss##* }
ie="$(step_range "Implement the task")"; i_start=${ie%% *}
if [ "$s_start" -gt 0 ] && [ "$s_end" -le "$i_start" ]; then
  ok "trusted scripts snapshotted before the agent runs"
else
  ko "trusted scripts snapshotted before the agent runs"
fi
assert_in "$workflow" "export runs from the trusted snapshot" \
  'bash "\$\{TRUSTED_SCRIPTS\}/export-changes.sh"'
assert_in "$workflow" "failed agent work is checkpointed from the trusted snapshot" \
  'bash "\$\{TRUSTED_SCRIPTS\}/checkpoint-on-failure.sh"'
assert_in "$workflow" "agent execution leaves recovery time" \
  'timeout-minutes: 35'
assert_in "$workflow" "checkpoint runs after a failed agent step" \
  "steps.agent.outcome == 'failure'"
assert_in "$workflow" "artifact upload also runs after a checkpoint" \
  "steps.checkpoint.outcome == 'success'"
assert_in "$workflow" "validation requires an uploaded artifact" \
  "needs.implement.outputs.artifact_ready == 'true'"
assert_in "$workflow" "publication requires fresh-runner validation" \
  "needs.validate.result == 'success'"
assert_in "$workflow" "interrupted implementations publish only as drafts" \
  "needs.implement.result != 'success' && 'true'"
assert_in "$workflow" "diagnostics redacted from the trusted snapshot" \
  'bash "\$\{TRUSTED_SCRIPTS\}/redact.sh"'
assert_in "$workflow" "validation runs from the trusted checkout" \
  "bash automation/scripts/opencode-ai-task/validate-changes.sh"

# --- Publication sequence -----------------------------------------------------
assert_in "$workflow" "publication runs the trusted publish script" \
  "bash automation/scripts/opencode-ai-task/publish-pr.sh"
assert_in "$workflow" "publication reads the validated artifact" \
  'ARTIFACT_DIR: \$\{\{ runner.temp \}\}/opencode-validated'
assert_not_in "$workflow" "publication step does not read artifact files from the work clone" \
  'cat issue-title.txt'
assert_in "$here/publish-pr.sh" "publication validates metadata before pushing" \
  "is missing from the validated artifact"
assert_in "$here/publish-pr.sh" "publication cleans up the branch if PR creation fails" \
  "no orphaned branch remains"
assert_not_in "$here/publish-pr.sh" "publish script keeps no token in remote URLs" \
  "x-access-token:.*@github"

# --- Failure notification -----------------------------------------------------
assert_in "$workflow" "notification passes stage results via environment" \
  'IMPLEMENT_RESULT: \$\{\{ needs.implement.result \}\}'
if grep -qE '\$\{needs\.[a-z]+\.result\}' "$workflow"; then
  ko "no GitHub expressions interpolated into Bash (\${needs.*})"
else
  ok "no GitHub expressions interpolated into Bash (\${needs.*})"
fi
assert_in "$workflow" "notification marked continue-on-error" \
  "continue-on-error: true"
assert_in "$workflow" "notification script exists and is executable" \
  "notify-failure.sh"

# --- Redaction is fail closed -------------------------------------------------
assert_not_in "$workflow" "redaction failures are not suppressed" \
  'redact.sh" "\$\{DIAG\}" 2>/dev/null \|\| true'
assert_not_in "$workflow" "redaction failures are not suppressed (bare)" \
  '\|\| true$.*redact|redact.*\|\| true'
assert_in "$workflow" "diagnostics upload gated on successful redaction" \
  "steps.diagnostics.outcome == 'success'"
assert_in "$here/redact.sh" "redaction verifies its own output" \
  "verify_clean"
assert_in "$workflow" "diagnostics use a log tail, not raw agent logs" \
  "opencode-log-tail.txt"

# --- Diagnostic secret safety -------------------------------------------------
diag="$(step_range "Collect and redact failure diagnostics")"; d_start=${diag%% *}; d_end=${diag##* }
if [ "$d_start" -gt 0 ] && sed -n "${d_start},${d_end}p" "$workflow" | grep -q -- "OPENCODE_API_KEY:"; then
  ok "diagnostics step receives the API key for redaction"
else
  ko "diagnostics step receives the API key for redaction"
fi
if sed -n "${d_start},${d_end}p" "$workflow" | grep -qE 'diff\.patch|cp -f "\$\{SPEC_FILE\}"|cp -f "\$\{PR_SUMMARY_FILE\}"'; then
  ko "diagnostics are minimal (no raw diff, spec or summary uploads)"
else
  ok "diagnostics are minimal (no raw diff, spec or summary uploads)"
fi
assert_in "$workflow" "diagnostics include only file-name lists" \
  "changed-files.txt"

# --- Dedicated CI regression workflow ----------------------------------------
tests_wf="$root/.github/workflows/opencode-ai-task-tests.yml"
if [ -f "$tests_wf" ]; then
  ok "dedicated security regression workflow exists"
else
  ko "dedicated security regression workflow exists"
fi
if grep -q "pull_request:" "$tests_wf" && grep -q "^on:" "$tests_wf"; then
  ok "regression workflow triggers on pull requests"
else
  ko "regression workflow triggers on pull requests"
fi
assert_not_in "$tests_wf" "regression workflow runs on every pull request (no paths filter)" \
  "^    paths:"
assert_in "$tests_wf" "regression workflow runs every test file" \
  'test-\*\.sh'
assert_in "$tests_wf" "regression workflow fails on any test failure" \
  "exit 1"
assert_in "$tests_wf" "regression workflow has read-only permissions" \
  "contents: read"
assert_in "$tests_wf" "regression workflow drops persisted credentials" \
  "persist-credentials: false"

# --- Artifact-only data flow ---------------------------------------------------
assert_in "$workflow" "implement uploads only the artifact directory" \
  'name: opencode-implementation'
assert_in "$workflow" "validate uploads only the validated artifact" \
  'name: opencode-validated'
assert_not_in "$workflow" "no job uploads repository or .git content" \
  "path: \\\$\{\{ github.workspace"
assert_in "$here/lib.sh" "artifact integrity manifest used" "SHA256SUMS"

# --- Hook and credential hygiene in publish -----------------------------------
assert_in "$here/publish-pr.sh" "publish disables hooks before authenticated ops" \
  'git -C "\$\{PUBLISH_WORK\}" config core.hooksPath'
assert_in "$here/publish-pr.sh" "publish supplies the token via GIT_ASKPASS" \
  'GIT_ASKPASS='
assert_not_in "$here/publish-pr.sh" "no token in remote URLs" \
  "x-access-token:.*@"
assert_in "$workflow" "publish revalidates before pushing" \
  "bash automation/scripts/opencode-ai-task/apply-validated.sh"
assert_in "$here/publish-pr.sh" "push uses an explicit branch refspec" \
  'git -C "\$\{PUBLISH_WORK\}" push --no-verify publish-origin "\$\{BRANCH\}:\$\{BRANCH\}"'
assert_in "$here/publish-pr.sh" "publish clears credential helpers" \
  'config credential.helper ""'

# --- Version pinning -----------------------------------------------------------
assert_in "$workflow" "OpenCode CLI version pinned" \
  "OPENCODE_CLI_VERSION: '2"
assert_in "$workflow" "workflow is reusable through workflow_call" \
  "workflow_call:"
assert_in "$workflow" "API key is an explicit reusable-workflow secret" \
  "OPENCODE_GO_API_KEY:"
assert_in "$workflow" "trusted scripts use the reusable workflow repository" \
  'repository: \$\{\{ job\.workflow_repository \}\}'
assert_in "$workflow" "trusted scripts use the reusable workflow commit" \
  'ref: \$\{\{ job\.workflow_sha \}\}'
assert_in "$workflow" "central and target checkouts are isolated" \
  "path: automation"
assert_in "$workflow" "target checkout has its own path" \
  "path: target"
assert_in "$workflow" "model selection runs from trusted scripts" \
  'TRUSTED_SCRIPTS\}/select-model.sh'
assert_in "$workflow" "model mapping is centrally owned" \
  'automation/config/models.conf'
assert_not_in "$workflow" "caller repository variables cannot select arbitrary models" \
  'vars\.OPENCODE_AI_TASK_MODEL'
assert_in "$workflow" "generic setup uses the caller workspace local action" \
  'uses: \./\.github/actions/setup-ai-task'

setup_range="$(step_range 'Set up consumer environment')"
implement_range="$(step_range 'Implement the task')"
setup_start=${setup_range%% *}
implement_start=${implement_range%% *}
if [ "${setup_start}" -gt 0 ] && [ "${setup_start}" -lt "${implement_start}" ]; then
  ok "optional consumer setup runs before OpenCode"
else
  ko "optional consumer setup runs before OpenCode"
fi
for privileged_job in validate publish; do
  privileged_range="$(job_block "${privileged_job}")"
  privileged_start=${privileged_range%% *}
  privileged_end=${privileged_range##* }
  if sed -n "${privileged_start},${privileged_end}p" "$workflow" | grep -q 'setup-ai-task'; then
    ko "${privileged_job} never executes consumer setup"
  else
    ok "${privileged_job} never executes consumer setup"
  fi
done
if grep -qiE 'rudiment|wasm32|trunk|cargo|toolchain_profile|npm ci|npm run build' \
  "$workflow" "$here/preflight.sh"; then
  ko "central production automation contains no consumer-specific toolchain or build logic"
else
  ok "central production automation contains no consumer-specific toolchain or build logic"
fi
assert_in "$root/SECURITY.md" "same-runner setup risk is documented" \
  'leave processes running'
assert_in "$root/SECURITY.md" "post-agent cache poisoning risk is documented" \
  'post-job saves of agent-modifiable paths'

# --- Never merge, never force, never deploy -----------------------------------
assert_not_in "$workflow" "no automatic merge" "gh pr merge"
assert_not_in "$workflow" "no marking PR ready for review" "gh pr ready"
assert_not_in "$workflow" "no admin bypass flags" --admin
assert_not_in "$workflow" "no unconstrained force pushes" "git push[^|]*--force([^ -]|[[:space:]])"
assert_in "$here/publish-pr.sh" "revision push uses an exact expected-head lease" \
  '--force-with-lease=refs/heads/\$\{BRANCH\}:\$\{BASE_SHA\}'
assert_in "$here/publish-pr.sh" "revision publication preserves ancestry" \
  'merge-base --is-ancestor'
assert_in "$here/publish-pr.sh" "revision mode updates without creating another PR" \
  'Revisions stop here: update the existing PR, never create another'
assert_in "$workflow" "revision mode requires App credentials" \
  'Revision mode requires GitHub App credentials'
assert_in "$workflow" "revision completion is recorded on the existing PR" \
  'Record completed revision on the pull request'
assert_in "$here/publish-pr.sh" "pull requests are drafts by default" "DRAFT_FLAG=\(--draft\)"
assert_in "$here/publish-pr.sh" "ready-for-review PRs are opt-in via PR_DRAFT" 'PR_DRAFT'
assert_in "$workflow" "draft input defaults to draft" "default: true"
assert_in "$workflow" "optional GitHub App publication token" "create-github-app-token"
assert_not_in "$workflow" "no pushes to the default branch" \
  'git push[^|]*"[[:space:]]*"?\$\{DEFAULT_BRANCH\}'
assert_in "$here/validate-changes.sh" \
  "validation refuses a task branch not matching the issue" \
  "does not match ai/issue"
assert_not_in "$workflow" "no deploy actions" "deploy-pages"

# --- Gate scripts executable ---------------------------------------------------
for s in authorise.sh authorise-revision.sh dedup-check.sh revision-gate.sh revision-status.sh checkpoint-on-failure.sh consumer-setup-actions.sh export-changes.sh validate-changes.sh apply-validated.sh redact.sh select-model.sh verify-trusted-checkout.sh; do
  if [ -x "$here/$s" ]; then ok "gate script executable: $s"; else ko "gate script executable: $s"; fi
done

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

