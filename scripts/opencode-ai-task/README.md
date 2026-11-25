# Trusted automation scripts

These scripts implement the reusable workflow's security-sensitive gates. They
were extracted from Rudiment commit
`1722fe880607367c3dc694a3fc65d0a8e5b4cfa7` and generalized without changing
the four-stage patch-artifact architecture.

Scripts that run after the model are either snapshotted before model execution
or freshly checked out from the central commit identified by
`job.workflow_sha`. Behavioral tests use only disposable local repositories,
stubbed GitHub commands, and dummy credentials.

Do not move validation into the caller repository, execute an artifact-provided
script, pass target Git metadata between jobs, expose GitHub credentials to the
model step, or add a model identifier without validating and allowlisting it.

See the repository [README](../../README.md), [security design](../../SECURITY.md),
and [testing guide](../../TESTING.md).
