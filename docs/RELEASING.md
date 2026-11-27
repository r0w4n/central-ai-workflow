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
7. Run caller dry-run, then a controlled live end-to-end test. Confirm the draft
   PR records the expected central SHA, complexity, and model.

Before merging a consumer migration that references an unmerged central branch,
replace the provisional SHA with the final reviewed release commit and repeat
dry-run validation.
