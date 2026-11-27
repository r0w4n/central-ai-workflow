#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
ko() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

export AUTOMATION_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export COMPLEXITY=medium
export MODEL=test/model
export GH_TOKEN=dummy-token
BRANCH=ai/issue-17

make_commit_artifact() {
  local trusted="$1" agent="$2" base="$3" comment_id="$4" text="$5" out="$6"
  git clone -q "$trusted" "$agent"
  git -C "$agent" checkout -q --detach "$base"
  git -C "$agent" checkout -q -b "$BRANCH"
  git -C "$agent" config user.name agent
  git -C "$agent" config user.email agent@example.com
  printf '%s\n' "$text" >>"$agent/app.txt"
  git -C "$agent" add app.txt
  git -C "$agent" commit -q -m "fix: revision from comment $comment_id"
  printf 'Revision %s implemented and tested.\n' "$comment_id" >"$tmp/summary-$comment_id.md"
  printf 'Original issue\n' >"$tmp/title-$comment_id.txt"
  (
    cd "$agent"
    TASK_MODE=revision PR_NUMBER=42 COMMENT_ID="$comment_id" ISSUE_NUMBER=17 \
      BRANCH="$BRANCH" BASE_SHA="$base" ARTIFACT_DIR="$out" \
      PR_SUMMARY_FILE="$tmp/summary-$comment_id.md" ISSUE_TITLE_FILE="$tmp/title-$comment_id.txt" \
      bash "$here/export-changes.sh" >/dev/null
  )
}

validate_and_apply() {
  local trusted="$1" base="$2" comment_id="$3" artifact="$4" prefix="$5"
  TASK_MODE=revision PR_NUMBER=42 COMMENT_ID="$comment_id" ISSUE_NUMBER=17 \
    BRANCH="$BRANCH" BASE_SHA="$base" ARTIFACT_DIR="$artifact" TRUSTED_REPO="$trusted" \
    WORK_DIR="$tmp/${prefix}-validate" VALIDATED_OUT="$tmp/${prefix}-validated" \
    bash "$here/validate-changes.sh" >/dev/null
  TASK_MODE=revision PR_NUMBER=42 COMMENT_ID="$comment_id" ISSUE_NUMBER=17 \
    BRANCH="$BRANCH" BASE_SHA="$base" ARTIFACT_DIR="$tmp/${prefix}-validated" TRUSTED_REPO="$trusted" \
    WORK_DIR="$tmp/${prefix}-publish" bash "$here/apply-validated.sh" >"$tmp/${prefix}-apply.out"
}

write_fake_gh() {
  local head="$1"
  cat >"$tmp/bin/gh" <<FAKEGH
#!/bin/sh
echo "\$*" >>"$tmp/gh.log"
if [ "\$1" = api ]; then
  printf '%s\n' '{"state":"open","merged":false,"base":{"ref":"main"},"head":{"ref":"ai/issue-17","sha":"$head","repo":{"full_name":"r0w4n/example"}}}'
  exit 0
fi
echo "unexpected gh call" >&2
exit 1
FAKEGH
  chmod +x "$tmp/bin/gh"
}

mkdir -p "$tmp/bin"
git init -q "$tmp/trusted"
git -C "$tmp/trusted" config user.name test
git -C "$tmp/trusted" config user.email test@example.com
printf 'base\n' >"$tmp/trusted/app.txt"
git -C "$tmp/trusted" add app.txt
git -C "$tmp/trusted" commit -q -m base
BASE1="$(git -C "$tmp/trusted" rev-parse HEAD)"
git init -q --bare "$tmp/remote.git"
git -C "$tmp/trusted" push -q "$tmp/remote.git" "$BASE1:refs/heads/$BRANCH"

make_commit_artifact "$tmp/trusted" "$tmp/agent1" "$BASE1" 9001 first "$tmp/artifact1"
validate_and_apply "$tmp/trusted" "$BASE1" 9001 "$tmp/artifact1" first
WORK1="$(sed -n 's/^WORK=//p' "$tmp/first-apply.out")"
write_fake_gh "$BASE1"
: >"$tmp/gh.log"
PATH="$tmp/bin:$PATH" TASK_MODE=revision PR_NUMBER=42 COMMENT_ID=9001 ISSUE_NUMBER=17 \
  BRANCH="$BRANCH" BASE_SHA="$BASE1" DEFAULT_BRANCH=main REPOSITORY=r0w4n/example \
  REMOTE_URL="$tmp/remote.git" PUBLISH_WORK="$WORK1" ARTIFACT_DIR="$tmp/first-validated" \
  PUBLICATION_RESULT_FILE="$tmp/result1" bash "$here/publish-pr.sh" >/dev/null
HEAD1="$(git -C "$tmp/remote.git" rev-parse "refs/heads/$BRANCH")"
check "revision adds a commit to the existing branch" "[ '$HEAD1' != '$BASE1' ]"
check "revision records the resulting commit" "grep -q \"commit_sha=$HEAD1\" '$tmp/result1'"
check "revision updates rather than creating a PR" "! grep -q 'pr create' '$tmp/gh.log'"

# A second comment starts from the first revision head and preserves it.
git clone -q --no-checkout "$tmp/remote.git" "$tmp/trusted2"
git -C "$tmp/trusted2" checkout -q --detach "$HEAD1"
make_commit_artifact "$tmp/trusted2" "$tmp/agent2" "$HEAD1" 9002 second "$tmp/artifact2"
validate_and_apply "$tmp/trusted2" "$HEAD1" 9002 "$tmp/artifact2" second
WORK2="$(sed -n 's/^WORK=//p' "$tmp/second-apply.out")"
write_fake_gh "$HEAD1"
: >"$tmp/gh.log"
PATH="$tmp/bin:$PATH" TASK_MODE=revision PR_NUMBER=42 COMMENT_ID=9002 ISSUE_NUMBER=17 \
  BRANCH="$BRANCH" BASE_SHA="$HEAD1" DEFAULT_BRANCH=main REPOSITORY=r0w4n/example \
  REMOTE_URL="$tmp/remote.git" PUBLISH_WORK="$WORK2" ARTIFACT_DIR="$tmp/second-validated" \
  PUBLICATION_RESULT_FILE="$tmp/result2" bash "$here/publish-pr.sh" >/dev/null
HEAD2="$(git -C "$tmp/remote.git" rev-parse "refs/heads/$BRANCH")"
check "consecutive revision adds another commit" "[ '$HEAD2' != '$HEAD1' ]"
check "consecutive revision preserves the prior head" "git -C '$tmp/remote.git' merge-base --is-ancestor '$HEAD1' '$HEAD2'"
check "consecutive revision still creates no PR" "! grep -q 'pr create' '$tmp/gh.log'"

# Build a third valid artifact, then move the remote branch before publish.
git clone -q --no-checkout "$tmp/remote.git" "$tmp/trusted3"
git -C "$tmp/trusted3" checkout -q --detach "$HEAD2"
make_commit_artifact "$tmp/trusted3" "$tmp/agent3" "$HEAD2" 9003 third "$tmp/artifact3"
validate_and_apply "$tmp/trusted3" "$HEAD2" 9003 "$tmp/artifact3" third
WORK3="$(sed -n 's/^WORK=//p' "$tmp/third-apply.out")"
git clone -q "$tmp/remote.git" "$tmp/competitor"
git -C "$tmp/competitor" checkout -q "$BRANCH"
git -C "$tmp/competitor" config user.name competitor
git -C "$tmp/competitor" config user.email competitor@example.com
printf 'competing\n' >>"$tmp/competitor/app.txt"
git -C "$tmp/competitor" add app.txt
git -C "$tmp/competitor" commit -q -m 'fix: competing update'
git -C "$tmp/competitor" push -q origin "$BRANCH"
COMPETING_HEAD="$(git -C "$tmp/remote.git" rev-parse "refs/heads/$BRANCH")"
write_fake_gh "$HEAD2"
PATH="$tmp/bin:$PATH" TASK_MODE=revision PR_NUMBER=42 COMMENT_ID=9003 ISSUE_NUMBER=17 \
  BRANCH="$BRANCH" BASE_SHA="$HEAD2" DEFAULT_BRANCH=main REPOSITORY=r0w4n/example \
  REMOTE_URL="$tmp/remote.git" PUBLISH_WORK="$WORK3" ARTIFACT_DIR="$tmp/third-validated" \
  PUBLICATION_RESULT_FILE="$tmp/result3" bash "$here/publish-pr.sh" >/dev/null 2>"$tmp/compete.err" && RC=0 || RC=$?
check "unexpected remote head rejects the revision" "[ '$RC' -ne 0 ]"
check "competing contributor commit is not overwritten" "[ \"\$(git -C '$tmp/remote.git' rev-parse 'refs/heads/$BRANCH')\" = '$COMPETING_HEAD' ]"
check "head-change rejection is explicit" "grep -q 'remote branch head changed' '$tmp/compete.err'"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
