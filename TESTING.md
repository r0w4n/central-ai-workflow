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
checkout isolation, and two target repositories with different structures.

Recent additions cover the workspace-root preflight (`test-preflight.sh`: the
Git root must resolve to `$GITHUB_WORKSPACE`, missing tools and toolchain
targets fail closed) and the publication-permission preflight
(`test-check-publish-permissions.sh`: read-only tokens and disabled
Actions-created pull requests fail with remediation, unverifiable APIs warn
and continue).

The dedicated CI workflow
`.github/workflows/opencode-ai-task-tests.yml` runs shell syntax, actionlint, and
every `test-*.sh` file on every pull request and on `main`.
