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
2. **Implement** checks out the caller under `target/` and the central workflow
   under `automation/`. It proves the central checkout equals
   `job.workflow_sha`, snapshots the scripts before the agent starts, selects
   an approved model, optionally provisions a centrally managed toolchain, and
   gives the agent only `OPENCODE_API_KEY`. The output is a restricted patch
   artifact—never the working tree or `.git` directory.
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

Callers that need the pinned Rust WASM/Trunk environment may opt into
`toolchain_profile: rust-wasm-trunk-0.22.1`. The default is `none`.
Profiles execute only central scripts from the verified workflow revision; the
reusable workflow never runs setup actions from the target checkout.

Required caller permissions are `contents: write`, `pull-requests: write`, and
`issues: write`. The called workflow narrows each job to the minimum it needs;
GitHub does not allow a called workflow to elevate beyond its caller.

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
  create pull requests.
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
