# Central AI Workflow

`central-ai-workflow` provides a reusable, security-hardened GitHub Actions
workflow that turns an authorised GitHub issue into a pull request and applies
authorised review feedback to that same PR using OpenCode. It was extracted
from the reviewed Rudiment automation at commit
`1722fe880607367c3dc694a3fc65d0a8e5b4cfa7`.

The reusable workflow is [`.github/workflows/opencode-ai-task.yml`](.github/workflows/opencode-ai-task.yml).
Consumers pin it by full commit SHA; a normal checkout always remains the
consumer's repository, while trusted scripts are fetched separately from this
repository at the exact SHA that defines the reusable job.

## Architecture and trust boundaries

```text
authorise (trusted API gate) -> implement (read + model secret) -> validate (read)
                                                                  -> publish (write)
                               failures --------------------------> notify (issue write)
```

1. **Authorise** supports two modes. Initial implementation checks the issue
   author, label, labeler, open state, body, and duplicate state. Revision mode
   re-reads the immutable feedback comment and verifies the human author, open
   PR state, Central AI provenance, automation PR author, approved base,
   same-repository `ai/issue-<n>` head, linked issue, and exact current head
   SHA. The central policy requires `r0w4n` and `ai-task`.
2. **Implement** checks out the caller at the runner workspace root, so
   `$GITHUB_WORKSPACE` is the Git repository root, and the central workflow
   under a temporary `automation/` directory that is removed before the agent
   starts. It proves the central checkout equals `job.workflow_sha`, snapshots
   the scripts before the agent starts, selects an approved model, optionally
   runs the consumer's `.github/actions/setup-ai-task` local action, and
   verifies the central runtime (working directory, Git checkout, and required
   orchestration tools) in a trusted preflight before giving the agent only
   `OPENCODE_API_KEY`. The output is a restricted patch artifact—never the
   working tree or `.git` directory. The agent has a 35-minute execution cap,
   with a reserved finish-and-commit budget. It runs focused consumer checks;
   the consumer PR workflows remain the comprehensive regression gate. If the
   agent step fails or times out, a trusted snapshot commits its remaining
   non-ignored work and exports the same restricted patch format.
3. **Validate** starts on a fresh runner, verifies checksums and metadata,
   applies patches with hooks and credential helpers disabled, and rejects
   protected paths, traversal, symlinks, submodules, malformed patches, merge
   commits, or central-version drift.
4. **Publish** starts on another fresh runner with GitHub write permission and
   re-runs validation. Initial mode pushes only `ai/issue-<n>` and opens one
   PR. Revision mode requires a GitHub App token, verifies the remote head still
   equals the pinned SHA, then uses an exact lease to append commits to the
   same branch. It never merges or updates the default branch.
   A failed implementation with a valid checkpoint is published only as a
   **draft recovery PR** after fresh-runner validation. A failed revision can
   append a validated checkpoint to the existing PR, preserving its history.
   The original run still reports failure, and project checks must pass before
   a human decides whether to merge.
5. **Notify** updates one comment-ID-keyed revision audit comment or reports an
   initial failure on the source issue.

Untrusted issue text is written to a file and passed to OpenCode as data. It is
never interpolated into executable shell. Agent-created Git metadata never
crosses jobs. Fresh target Git metadata in validation/publication comes only
from the pinned base checkout.

See [SECURITY.md](SECURITY.md) for the full threat model and
[TESTING.md](TESTING.md) for the regression matrix.

## Onboard a repository

Copy the generic caller from
[`examples/generic-opencode-ai-task.yml`](examples/generic-opencode-ai-task.yml)
to `.github/workflows/opencode-ai-task.yml` in the target repository, replace
`<CENTRAL_RELEASE_SHA>` with a reviewed 40-character commit SHA, and add the
`OPENCODE_GO_API_KEY` Actions secret.

The target repository owns its source, issues, `AGENTS.md`, development
instructions, and PR quality gates. The agent reads those instructions and runs
focused QA before committing; normal target-repository PR workflows remain
the authoritative merge gates. Project configuration cannot bypass central
artifact validation or change the approved model allowlist.

For browser tests, the consumer must ensure a clean-base comparison uses a
freshly built application. A checkout or stash without rebuilding cannot prove
that a failure predates the task. Agent instructions limit unchanged test
retries and require a short diagnosis when validation remains failing.

Repositories that need environment preparation set `setup: true` and provide a
local composite action at `.github/actions/setup-ai-task/action.yml`. The
action may use normal GitHub Actions setup and cache mechanisms for any stack.
Repositories that need no preparation omit the input (the default is `false`).
The action should install dependencies, make required tools available through
standard GitHub environment files, verify their versions, and report its cache
and timing diagnostics. It should not perform a mandatory full application
build: project validation remains the agent's responsibility and the target
repository's pull-request checks remain the authoritative merge gates.

Setup may restore reviewed caches, but it must not schedule post-job saves of
paths the later agent can modify under a trusted/default-branch cache scope.
Disable saves for the AI job or save immutable dependency data before the local
action returns. Never cache credentials, model sessions, issue data, or agent
state.

The setup action comes from the immutable caller revision (`github.sha`) and
runs only in the implementation job. This allows revision of an older PR head
that predates the consumer's setup action. The workflow temporarily stages the
caller's local actions at their normal workspace paths, then restores the PR
head's files and removes the setup checkout before OpenCode starts. Manual
retries should dispatch the caller workflow from the approved base branch.
After setup runs, the rest of that runner must be
treated as consumer-controlled: a process can persist, alter tools or modify
the workspace across later steps. Consequently the job has no repository write
permission or publication credential. Validation and publication use fresh
runners and never execute the consumer action. The model API key is necessarily
used later in the same implementation job, so consumers must review their base
setup action with the same care as any other code that runs alongside the
agent.

Publication defaults to a **draft** pull request. Callers may pass
`draft: false` to publish the pull request ready for review; merging always
remains a manual action. When callers also provide the optional
`APP_ID` and `APP_PRIVATE_KEY` secrets for a GitHub App installed on
the target repository (with contents: write and pull requests: write), the
publish stage mints a
short-lived App installation token for the branch push and pull request
creation. Pull requests created with an App token trigger the target
repository's own `pull_request` workflows automatically, without the
held-for-approval gate that GitHub applies to `GITHUB_TOKEN`-created pull
requests. Without App credentials the reusable workflow falls back to
`GITHUB_TOKEN` and its documented manual repository settings.

Before the agent starts, the implement job runs a trusted preflight that fails
closed when `git rev-parse --show-toplevel` does not resolve to
`$GITHUB_WORKSPACE`, or when a tool required by central orchestration (Git,
Node, npm, or OpenCode) is missing. Project-tool verification belongs in the
consumer action. The authorise job preflights the
repository's Actions settings that gate pull request publication.

Required caller permissions are `contents: write`, `pull-requests: write`, and
`issues: write`. The called workflow narrows each job to the minimum it needs;
GitHub does not allow a called workflow to elevate beyond its caller.

### Repository settings that workflow YAML cannot change

Two manual repository settings must be enabled; declaring
`permissions:` in the caller cannot replace them:

1. **Read and write workflow token permissions.** Settings > Actions >
   General > Workflow permissions > *Read and write permissions*.
2. **Allow GitHub Actions to create and approve pull requests.** Settings >
   Actions > General > Workflow permissions > enable the checkbox. Without it,
   the publication stage fails with `GitHub Actions is not permitted to create
   or approve pull requests` even though the branch push succeeds.

The authorise stage queries
`GET /repos/{owner}/{repo}/actions/permissions/workflow` and fails with these
remediation instructions before implementation begins; if the API cannot
verify the settings with the available token, it warns so the settings can be
checked manually.

## Review feedback and repeated revisions

Consumers forward `issue_comment: created` events to the reusable workflow. On
an open AI-generated PR, the authorised human writes:

```text
/ai revise Describe the focused correction to make.
```

The explicit command is retained for compatibility, but it is not required: any
ordinary actionable comment from the authorised human on an AI-generated PR
starts a revision the same way. Central AI classifies each comment locally:

- explicit `/ai revise <feedback>` commands work exactly as before;
- ordinary actionable feedback is accepted as a revision request;
- recognised but malformed commands (for example `/ai assist` or a bare
  `/ai revise`) get a public reply explaining the valid usage — they are never
  silently ignored;
- comments that look like a directive but are too vague (or bare questions) get
  an acknowledgement asking for a concrete change;
- bot comments, automation status updates, pleasantries and unauthorised
  feedback are ignored silently.

Central AI acknowledges the request, queues it behind earlier feedback for the
same PR, checks out the current PR head, and supplies the original issue,
current PR description, Git history, and new feedback to OpenCode. It then
uses the same fresh-runner artifact validation as initial implementation and
appends the result to the existing branch. The App-authenticated push emits the
normal `pull_request/synchronize` event, so consumer-owned checks and preview
workflows rerun without Central knowing the consumer's toolchain.

Each immutable comment ID is processed once. A single audit comment links the
workflow run and resulting commit. Bot comments, forks, unexpected
branches/authors, changed heads, closed or merged PRs, and unauthorised humans
are rejected. Feedback is untrusted task data and cannot change model policy,
permissions, protected paths, credentials, or publication behavior.

The trusted authorise and notify jobs need `pull-requests: write` to create or
update the status comment on a PR timeline. GitHub's issue-comment REST
documentation also lists `issues: write`, but a workflow token with only
`issues: write` and `pull-requests: read` can receive HTTP 403 for a PR
comment. The authorise job uses only `issues: read` for the linked issue; the
notify job also needs `issues: write` for initial issue status. OpenCode never
receives either job's GitHub token. Status failures identify the REST operation
and required permission in the workflow log.

Revision mode requires `APP_ID` and `APP_PRIVATE_KEY`, because GitHub suppresses
new workflow runs for pushes made with `GITHUB_TOKEN`. Set
`automation_pr_author` to the login that creates initial PRs, such as
`central-ai-publisher[bot]`. Retry a failed revision by manually dispatching
the consumer workflow in `revision` mode with the existing PR number and the
original comment ID; GitHub's **Re-run jobs** action is also accepted.

## Automatic CI-failure remediation

Remediation mode (`task_mode: remediation`) closes the CI loop without human
intervention. The consumer owns the event wiring; Central owns the policy,
state and execution:

1. The consumer's router workflow listens for `workflow_run: completed` events
   of the check workflows it cares about, resolves the AI-generated PR that
   owns the head commit (via `GET /repos/<owner>/<repo>/pulls?head=<owner>:<branch>`
   — the owner, not the full repository name, and URL-encoded query
   parameters), waits for concurrent checks to quiesce, and dispatches
   the task workflow with `task_mode: remediation`, the PR number,
   `remediation_run_id`, and `remediation_event: checks-failed` (or
   `checks-passed` when everything is green, which only closes the episode).
2. Central revalidates everything authoritatively: the PR must be open,
   same-repository, on an approved `ai/issue-<n>` branch, created by the
   approved automation App with Central provenance, and attached to an open
   labelled issue. Failing checks are re-read from the **current** head commit,
   so stale events for superseded commits are dropped instead of remediating.
3. A single persistent status comment per PR records the episode: current
   status, failing checks, attempt number and limit, corrective summary,
   workflow links and the final outcome.
4. Remediation reuses the implementation pipeline: the agent receives the
   original issue, the PR description, failing check names and redacted log
   excerpts, must reproduce failures locally, fix root causes, and is
   forbidden from weakening assertions or touching protected paths. The push
   uses the same exact head-SHA lease as revisions and reruns consumer checks.
5. Attempts are counted per failure episode (one episode spans the commits the
   remediation itself pushes) and are bounded by `remediation_max_attempts`
   (default 3). Failed attempts dispatch a bounded retry automatically; a
   head that is not a descendant of the episode's last commit starts a fresh
   episode; exhausting the limit escalates with actionable diagnostics and
   stops the loop.
6. Manual revisions and automatic remediation share one per-PR concurrency
   queue, so competing agents are impossible. Nothing is ever auto-approved or
   merged, and human-created PRs are never touched.

Consumers need `actions: write` in the calling workflow's permissions. The
reusable workflow's notify job statically requests `actions: write` to
dispatch bounded remediation retries via `caller_workflow`, and a nested job
may never request more than its caller grants — a caller that grants only
`actions: read` (or omits the scope) makes the whole caller workflow invalid
on every event. Failing-check verification goes through the Checks API, so
callers must also grant `checks: read`; job-log excerpts additionally need
`actions: read`. A missing grant makes the remediation gate fail with an
explicit API-error diagnostic instead of silently skipping — remediation is
never guessed from an unverifiable result. Log retrieval and
episode-state parsing happen in Central; consumers never duplicate that logic.

## Complexity and model selection

ChatGPT-generated development specifications may include one strict metadata
block anywhere in the issue body:

```markdown
<!-- ai-task-config
complexity: medium
model: opencode-go/glm-5.3-flash
-->
```

`complexity` is `simple`, `medium`, or `complex`. If the block or field is
absent, the documented default is `medium`. `model` is optional and must be an
exact member of the central allowlist. Duplicate blocks, unknown fields,
unsupported complexity values, malformed content, and unapproved models fail
closed.

Mappings live in [`config/models.conf`](config/models.conf). All three classes
currently map to the previously validated model
`opencode-go/glm-5.3-flash`; no unverified identifiers have been invented.
Maintainers may change a mapping centrally after validating a model and adding
it to `allowed_model`. Runner sizing remains independent of model selection.
The draft PR records complexity, model, and central automation SHA.

## Manual and live testing

The caller exposes manual modes for initial implementation and a failed
revision retry. Dry-run performs authorisation and duplicate/idempotency checks
only. For a live end-to-end test, use an open issue authored
and labelled `ai-task` by `r0w4n`, set `dry_run: false`, then confirm that a
draft `ai/issue-<n>` PR is created and that a second run is rejected as a
duplicate. Then add `/ai revise` feedback and confirm the same PR receives one
descendant commit, its checks rerun, and a second feedback comment produces a
second commit. Close the scratch PR and delete its branch afterward.

## Production settings

Required:

- Actions must be enabled and permitted to call this public reusable workflow.
- Add the `OPENCODE_GO_API_KEY` repository secret.
- Set Actions workflow permissions to read/write and enable GitHub Actions to
  create pull requests (Settings > Actions > General > Workflow permissions).
  These are manual repository settings; workflow YAML cannot enable them, and
  the authorisation preflight fails with remediation instructions when the API
  can detect they are missing.
- Protect the default branch and require the target repository's own QA checks.
- Pin the caller to a reviewed full central commit SHA.

Recommended:

- Require the central **OpenCode AI task security regression tests** check on
  central-repository pull requests.
- Require approval for workflow runs on bot-created or first-time PRs where the
  repository's policy supports it.
- Retain the default seven-day restricted-artifact lifetime, or reduce it to
  match organizational policy.

Release and pin-update instructions are in [docs/RELEASING.md](docs/RELEASING.md).
