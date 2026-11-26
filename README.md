# Central AI Workflow

`central-ai-workflow` provides a reusable, security-hardened GitHub Actions
workflow that turns an authorised GitHub issue into a draft pull request using
OpenCode. It was extracted from the reviewed Rudiment automation at commit
`1722fe880607367c3dc694a3fc65d0a8e5b4cfa7`.

The reusable workflow is [`.github/workflows/opencode-ai-task.yml`](.github/workflows/opencode-ai-task.yml).
Consumers pin it by full commit SHA; a normal checkout always remains the
consumer's repository, while trusted scripts are fetched separately from this
repository at the exact SHA that defines the reusable job.

## Architecture and trust boundaries

```text
authorise (read) -> implement (read + model secret) -> validate (read)
                                                    -> publish (write)
                         failures ------------------> notify (issue write)
```

1. **Authorise** checks the issue author, label, labeler, open state, non-empty
   body, non-PR status, and duplicate branch/PR state. The central default
   policy requires `r0w4n` and `ai-task`; callers cannot relax it.
2. **Implement** checks out the caller at the runner workspace root, so
   `$GITHUB_WORKSPACE` is the Git repository root, and the central workflow
   under a temporary `automation/` directory that is removed before the agent
   starts. It proves the central checkout equals `job.workflow_sha`, snapshots
   the scripts before the agent starts, selects an approved model, optionally
   runs the consumer's `.github/actions/setup-ai-task` local action, and
   verifies the central runtime (working directory, Git checkout, and required
   orchestration tools) in a trusted preflight before giving the agent only
   `OPENCODE_API_KEY`. The output is a restricted patch artifact—never the
   working tree or `.git` directory.
3. **Validate** starts on a fresh runner, verifies checksums and metadata,
   applies patches with hooks and credential helpers disabled, and rejects
   protected paths, traversal, symlinks, submodules, malformed patches, merge
   commits, or central-version drift.
4. **Publish** starts on another fresh runner with the only GitHub content/PR
   write permission. It re-runs validation, pushes only `ai/issue-<n>`, and
   opens a draft PR. It never merges, force-pushes, or updates the default
   branch. A failed PR creation removes the pushed branch.
5. **Notify** can only comment on the source issue after a downstream failure.

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
the relevant QA before committing; normal target-repository PR workflows remain
the authoritative merge gates. Project configuration cannot bypass central
artifact validation or change the approved model allowlist.

Repositories that need environment preparation set `setup: true` and provide a
local composite action at `.github/actions/setup-ai-task/action.yml`. The
action may use normal GitHub Actions setup and cache mechanisms for any stack.
Repositories that need no preparation omit the input (the default is `false`).
The action should install dependencies, make required tools available through
standard GitHub environment files, verify their versions, and report its cache
and timing diagnostics. It should not perform a mandatory full application
build: project validation remains the agent's responsibility and the target
repository's pull-request checks remain the authoritative merge gates.

The setup action comes from the consumer's pinned base revision and runs only
in the implementation job. After it runs, the rest of that runner must be
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

The caller exposes `workflow_dispatch` with a numeric `issue_number` and a
`dry_run` flag that defaults to `true`. Dry-run performs authorisation and
duplicate checks only. For a live end-to-end test, use an open issue authored
and labelled `ai-task` by `r0w4n`, set `dry_run: false`, then confirm that a
draft `ai/issue-<n>` PR is created and that a second run is rejected as a
duplicate. Close the scratch PR and delete its branch afterward.

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
