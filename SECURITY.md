# Security design

## Threat model

Issue titles and bodies are untrusted and may contain prompt injection or shell
metacharacters. The OpenCode process and everything it writes are untrusted. It
may attempt to replace validation scripts, create Git hooks, configure
credential helpers, craft malicious patches, or expose credentials. The GitHub
write token must never be available to the model process.

## Controls

- Central scripts are checked out separately from the caller repository using
  `job.workflow_repository` and `job.workflow_sha`. The verifier requires the
  reusable workflow ref to be a full immutable SHA and checks the checkout's
  actual `HEAD`. Implement snapshots these scripts before the agent runs.
- Authorisation completes before any model or model secret is used. The
  `r0w4n` author/labeler policy and `ai-task` label are centrally owned.
- OpenCode receives `OPENCODE_API_KEY`, but no `GH_TOKEN`, `GITHUB_TOKEN`,
  persisted checkout credential, or repository write permission.
- Optional project toolchains are an allowlist of central scripts copied from
  the verified workflow revision. They run in the read-only implementation job
  before the model secret is placed in a step environment; caller-controlled
  setup actions are never executed.
- Only numbered binary `format-patch` files, bounded text metadata, and a
  checksum manifest cross the implementation boundary. No repository or Git
  directory is uploaded.
- Validation uses a fresh pinned target checkout and trusted central script.
  It disables hooks and credential helpers before applying patches, performs
  text and resulting-tree checks, and regenerates the validated artifact.
- `.github/`, `.githooks/`, `.gitmodules`, Git-internal paths, and the legacy
  `scripts/opencode-ai-task/` path are protected. Symlinks, submodules, path
  traversal, malformed patches, merge commits, and metadata mismatches fail
  closed.
- Publication holds narrowly scoped `contents: write` and
  `pull-requests: write` permissions. It revalidates before authentication,
  supplies its token through `GIT_ASKPASS`, pushes an explicit task-branch
  refspec, creates only a draft PR, and removes an orphan branch on failure.
- Diagnostics contain only a redacted log tail and filename/status lists. A
  failed redaction prevents upload.
- Failure notification has issue-write permission only and is best-effort, so
  notification errors cannot conceal the original failure.

## Central versus project policy

Projects control their code, `AGENTS.md`, issue specifications, and QA
workflows. They do not control protected-path validation, authorisation,
credential isolation, model allowlisting, artifact validation, publication, or
central version verification. Changes to those boundaries require review in
this repository and a new immutable caller pin.

Report suspected vulnerabilities privately to the repository owner. Do not
exercise a live exploit against production repositories or credentials.
