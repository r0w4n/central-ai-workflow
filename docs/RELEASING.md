# Releasing and updating consumers

1. Develop central changes on a branch and open a pull request. Never place
   unreviewed automation directly on `main`.
2. Run shell syntax checks, actionlint, and the complete regression suite.
3. Review trust-boundary, permission, model-policy, and artifact-format changes
   explicitly. Merge only after the required central checks pass.
4. Record the reviewed commit SHA from `main`. A release tag may aid discovery,
   but consumers must pin the full SHA rather than the mutable tag.
5. Update each caller's `uses:` value to that SHA in its own reviewed PR. Do
   not change only a duplicated script ref: the workflow itself derives the
   trusted script checkout from its defining SHA.
6. When migrating from a removed or changed interface, merge central first,
   record its reviewed `main` SHA, update the consumer PR from its provisional
   pin to that exact SHA, and document any required consumer-owned local action.
7. Run caller dry-run, then a controlled live end-to-end test. Confirm the PR
   records the expected central SHA, complexity, and model. Add an authorised
   `/ai revise` comment and confirm a new commit lands on the same PR, normal
   checks rerun, and any configured preview updates.
8. For a coordinated Central/consumer revision release, open the Central PR
   first. Pin the consumer PR provisionally to the reviewed Central PR head so
   hosted caller validation can run. Merge Central, replace the consumer pin
   with Central's reviewed `main` merge commit, rerun validation, then merge
   the consumer. Never merge a consumer with only an unmerged provisional pin
   or mutable tag/branch reference.
9. When adopting checkpoint recovery, review a controlled failure run as well
   as a successful run: confirm that a changed tree becomes a restricted
   artifact, passes fresh-runner validation, and opens only a draft recovery
   PR. Confirm a protected-path checkpoint is rejected and no incomplete work
   reaches the default branch. Consumers need no new workflow input, but should
   update their agent guidance for focused checks and fresh browser builds.

Before merging a consumer migration that references an unmerged central branch,
replace the provisional SHA with the final reviewed release commit and repeat
dry-run validation.
