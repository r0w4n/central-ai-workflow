# Trusted automation scripts

These scripts implement the reusable workflow's security-sensitive gates. They
were extracted from Rudiment commit
`1722fe880607367c3dc694a3fc65d0a8e5b4cfa7` and generalized without changing
the four-stage patch-artifact architecture.

- `preflight.sh` runs from the trusted snapshot in the implementation job
  before the agent starts. It fails closed when the Git root does not resolve
  to `$GITHUB_WORKSPACE` or a required tool is missing, and logs the working
  directory, Git checkout, and tool versions.
- `check-publish-permissions.sh` runs in the authorise job. It checks the
  repository Actions settings that gate publication (`GET /repos/{owner}/
  {repo}/actions/permissions/workflow`) and fails closed with remediation
  before implementation; an unverifiable API warns and continues.

Scripts that run after the model are either snapshotted before model execution
or freshly checked out from the central commit identified by
`job.workflow_sha`. Behavioral tests use only disposable local repositories,
stubbed GitHub commands, and dummy credentials.

Do not move validation into the caller repository, execute an artifact-provided
script, pass target Git metadata between jobs, expose GitHub credentials to the
model step, or add a model identifier without validating and allowlisting it.
Project-specific setup, dependency caches, and builds belong in the consumer's
optional `.github/actions/setup-ai-task` action and pull-request workflows, not
in these trusted scripts.

See the repository [README](../../README.md), [security design](../../SECURITY.md),
and [testing guide](../../TESTING.md).
