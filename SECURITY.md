# Security design

## Threat model

Issue titles, PR descriptions, and comments are untrusted and may contain
prompt injection or shell metacharacters. The OpenCode process and everything
it writes are untrusted. It
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
- Revision authorisation is repeated from GitHub API state inside the trusted
  workflow. It binds an immutable comment ID to an authorised human, open
  same-repository PR created by the configured automation bot, approved base,
  `ai/issue-<n>` head, authorised linked issue, and pinned head SHA. Ordinary
  comments are classified by a pure, local classifier before anything is
  executed; bot comments, automation status updates, pleasantries and
  unauthorised feedback are ignored without spawning an agent.
- Automatic CI remediation is bound to the PR head that actually exists when
  the remediation runs: failing checks are read from the current head commit,
  stale events for superseded commits are dropped, and publication reuses the
  exact expected-head lease. Remediation attempts are counted per failure
  episode in one persistent status comment, bounded by
  `remediation_max_attempts`, and exhausting the limit escalates to a human
  instead of looping. Failed attempts dispatch bounded retries only through
  the caller's own workflow; the retry is reauthorised from scratch. Manual
  revisions and automatic remediation share one per-PR concurrency queue.
  Remediation never touches check configuration, and an escalated or
  ready-for-review episode cannot be re-run automatically. Failing-check
  verification requires `actions: read`; when check runs cannot be verified,
  remediation is skipped rather than guessed. Remediation log excerpts are
  untrusted CI output: they are redacted before entering the agent context and
  withheld entirely when redaction cannot verify them.
- Comment feedback is never used for model selection and cannot alter workflow
  permissions, secrets, protected paths, or publication policy. Status comments
  do not begin with `/ai revise`, preventing bot-comment loops.
- Only trusted authorise, publish, and notify jobs can write PR timeline status
  comments. Their `pull-requests: write` grants stay separate from the read-only
  implementation and validation jobs. A PR comment POST can fail with HTTP 403
  under `issues: write` alone, despite the REST documentation listing that
  permission as sufficient.
- OpenCode receives `OPENCODE_API_KEY`, but no `GH_TOKEN`, `GITHUB_TOKEN`,
  persisted checkout credential, or repository write permission.
- An optional consumer-owned `.github/actions/setup-ai-task` action runs only
  in the read-only implementation job, before the model credential is placed
  in a step environment. It is checked out from the immutable caller revision
  rather than the potentially older AI PR head, and its files are removed from
  the agent checkout after setup. Step-scoped variables are not treated as isolation:
  setup can leave processes running, alter `PATH`, replace tools, or modify the
  checkout before later steps. The whole remaining runner is therefore
  considered consumer-controlled. It never receives publication credentials
  or repository write permission; fresh validation and publication jobs never
  execute consumer setup. The reviewed base repository is part of the trust
  base for the model API key already required to run project tooling. Consumer
  cache actions must also disable post-job saves of agent-modifiable paths (or
  save before setup returns), preventing an implementation run on the default
  ref from poisoning caches later restored by trusted jobs.
- A trusted preflight runs after optional consumer setup and before the model: it
  fails closed unless `git rev-parse --show-toplevel` resolves to
  `$GITHUB_WORKSPACE` and every central orchestration tool is present. The automation
  checkout is removed from the workspace before the agent starts, so the agent
  sees a single clean repository.
- Only numbered binary `format-patch` files, bounded text metadata, and a
  checksum manifest cross the implementation boundary. No repository or Git
  directory is uploaded.
- A failed or timed-out agent may leave a dirty tree. The trusted checkpoint
  step creates a local commit and exports it through the same restricted
  artifact path. It has no publication credential. A checkpoint is never
  trusted because it was committed; fresh-runner validation applies every
  protected-path, mode, integrity, and pinned-base check before publication.
  A recovered initial task opens a draft PR only, and no recovery path merges.
- Validation uses a fresh pinned target checkout and trusted central script.
  It disables hooks and credential helpers before applying patches, performs
  text and resulting-tree checks, and regenerates the validated artifact.
- `.github/`, `.githooks/`, `.gitmodules`, Git-internal paths, and the legacy
  `scripts/opencode-ai-task/` path are protected. Symlinks, submodules, path
  traversal, malformed patches, merge commits, and metadata mismatches fail
  closed.
- Publication holds narrowly scoped `contents: write`, `issues: write`, and
  `pull-requests: write` permissions. It revalidates before authentication and
  supplies its token through `GIT_ASKPASS`. Revision mode requires App
  credentials and uses an exact expected-head lease after proving the new head
  descends from the pinned head; a concurrent update therefore fails instead
  of being overwritten. Initial mode creates one configured reviewable PR and
  removes an orphan branch on failure.
  A preflight in the authorise stage checks the repository's Actions workflow
  permissions and fails closed before implementation when they would reject
  publication; when the API is unverifiable, it warns instead so manual
  verification instructions are shown without inventing access.
- Diagnostics contain only a redacted log tail and filename/status lists. A
  failed redaction prevents upload.
- Failure notification has issue-write permission only and is best-effort, so
  notification errors cannot conceal the original failure.
- Native per-PR concurrency queues comments with cancellation disabled. A
  comment-ID marker prevents duplicate implementation and records accepted,
  completed, failed, or rejected status. Failed requests can be retried
  explicitly; completed requests cannot be replayed.

## Central versus project policy

Projects control their code, `AGENTS.md`, issue specifications, and QA
workflows, including their optional environment setup, dependency caches, and
build commands. They do not control protected-path validation, authorisation,
credential isolation, model allowlisting, artifact validation, publication, or
central version verification. Changes to those boundaries require review in
this repository and a new immutable caller pin.

Report suspected vulnerabilities privately to the repository owner. Do not
exercise a live exploit against production repositories or credentials.
