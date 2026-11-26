# Central AI Workflow agent instructions

## Architectural invariant

Central AI knows how to run an autonomous development task. The consuming
repository knows how to build and test its application.

The central workflow must remain technology-agnostic. It owns issue
authorisation and deduplication, repository and branch orchestration, model
selection and OpenCode execution, generic recovery and timeout behaviour,
restricted change artifacts, secure pull-request publication, logging, error
handling, and security controls.

Apply this architectural test before adding functionality:

> Would this functionality be required by an unrelated project using a
> completely different technology stack? If not, it probably belongs in the
> consuming repository.

## Rules for changes

1. Never hard-code a consumer's programming language, compiler, runtime,
   package manager, toolchain, framework, dependency installation, build
   command, cache path, or application name into central automation.
2. Keep project-specific environment configuration, compilation, tests,
   caching, deployment, and preview behaviour in the consuming repository.
3. Support new consumers through the smallest documented generic interface;
   do not add central profiles, allowlists, or special cases for individual
   projects.
4. Preserve central security boundaries: least-privilege jobs, credential
   isolation, immutable workflow pins, restricted artifacts, trusted fresh-runner
   validation and publication, and manual merge approval.
5. Treat consumer setup and the agent workspace as untrusted for later steps on
   the same runner. Never expose publication credentials there or rely on
   step-scoped environment variables as an isolation boundary.
6. Avoid unnecessary infrastructure, persistent runners, orchestration layers,
   and custom frameworks. Prefer straightforward GitHub Actions features.
7. Prefer established GitHub Actions mechanisms for caches, artifacts, and
   dependency management, owned and configured by each consumer.
8. Avoid redundant compilation and unnecessary dependency installation. The
   central preflight verifies only the tools central orchestration itself needs.
9. Changes to central interfaces require compatibility tests, updated examples,
   and explicit migration and immutable-SHA release guidance.
10. Keep README, SECURITY, TESTING, scripts, examples, and automated tests
    aligned with these principles. Tests must reject project-specific production
    logic rather than merely documenting it.

Do not weaken protected-path validation, allow untrusted Git metadata or setup
outputs to cross trust boundaries, automatically merge, or move authoritative
project QA into this repository.
