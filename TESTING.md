# Testing

Run the complete local suite from the repository root:

```sh
for test_file in scripts/opencode-ai-task/test-*.sh; do
  bash "$test_file"
done
```

Also run:

```sh
bash -n scripts/opencode-ai-task/*.sh
actionlint -ignore 'property "workflow_(repository|sha|ref)" is not defined'
git diff --check
```

The narrow actionlint exception exists because actionlint 1.7.12 does not yet
model GitHub's documented `job.workflow_repository`, `job.workflow_sha`, and
`job.workflow_ref` properties. No other lint diagnostic is ignored.

The regression suite covers authorisation, duplicate prevention, restricted
artifact export, checksum and metadata integrity, protected paths, symlinks,
submodules, traversal, malicious hooks and credential helpers, publication and
orphan cleanup, failure notifications, diagnostic redaction, version drift,
complexity/model selection, rejected models/configuration, central-versus-target
checkout isolation, the optional consumer setup contract, the no-setup default,
absence of project-specific production logic, and target repositories with
different structures.

`test-checkpoint.sh` simulates a timed-out agent on a detached checkout with
tracked and new files. It verifies that a checkpoint commit exports as a patch
artifact, passes the fresh-base validator, and refuses an unexpected branch.
`test-workflow.sh` checks the 35-minute agent cap, recovery-step ordering,
artifact gating, fresh validation, and forced draft status for recovery PRs.
Consumer CI remains responsible for the full application test suite; the agent
runs only focused checks while implementing.

Revision coverage uses realistic GitHub REST and event payloads.
`test-revision.sh` exercises authorised feedback, empty/malformed commands,
unauthorised and bot authors, provenance, fork/base/branch checks, closed or
merged PR rejection, and audit comments. `test-revision-publish.sh` proves two
consecutive comments add commits to one existing PR branch, no second PR is
created, and a concurrent head update is refused without overwriting it.
Static checks cover event routing, per-PR concurrency, App publication,
protected paths, failure status, and the absence of consumer build logic.
`test-consumer-setup-actions.sh` exercises a revision head that predates its
local setup action, nested local action resolution, exact restoration of an
older head's action files, and failure when the caller has no setup action.

Feedback classification and automated remediation have dedicated coverage.
`test-feedback-classify.sh` pins the classifier contract: explicit
`/ai revise` commands, malformed commands such as `/ai assist` and bare
`/ai revise`, ordinary actionable feedback, vague comments and bare questions
(acknowledged rather than executed), pleasantries, emoji reactions, automation
markers and blank comments (ignored silently). `test-remediation.sh` covers the
remediation policy and its network gate: first-failure episodes, attempt
accounting across pushed corrections, fresh episodes on unrelated heads,
in-progress deduplication and self-recheck, stale takeover, configurable
attempt limits, escalation after the limit, `checks-passed` episode closure,
trigger-actor policy, fork refusal, and the persistent status comment marker
and lifecycle (in progress, completed, failed, escalated, ready for review).
`test-workflow.sh` additionally asserts that remediation is gated to router
events, silent feedback is never answered publicly, and retry dispatch depends
on the caller workflow input.

Recent additions also cover the workspace-root preflight (`test-preflight.sh`: the
Git root must resolve to `$GITHUB_WORKSPACE` and missing central tools fail
closed), the generic local-action interface and its fresh-runner security
boundary (`test-workflow.sh`), and the publication-permission preflight
(`test-check-publish-permissions.sh`: read-only tokens and disabled
Actions-created pull requests fail with remediation, unverifiable APIs warn
and continue).

The dedicated CI workflow
`.github/workflows/opencode-ai-task-tests.yml` runs shell syntax, actionlint, and
every `test-*.sh` file on every pull request and on `main`.
