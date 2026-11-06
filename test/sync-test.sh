#!/usr/bin/env bash
# Tests for sync.sh. Each case builds a fake upstream and a fake fork (a bare repo standing in for GitHub) in a temp
# folder, then runs `sync.sh prepare` and `sync.sh publish` in separate clones, as the workflow's two jobs do.
# `git push` and `gh` are stubs (test/stubs/): pushes, issues and releases are only logged, so nothing leaves the temp
# folder. Needs bash, git >= 2.40, tar and coreutils; no Node, no network.
#   bash test/sync-test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sync=$here/../sync.sh
REAL_GIT=$(command -v git)
T=$(mktemp -d "${TMPDIR:-/tmp}/acp-fork-sync-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# a private HOME and git config: nothing reads or writes the caller's
export HOME=$T/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$T/home/.gitconfig
mkdir -p "$HOME" "$T/bin"
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.test
cp "$here/stubs/git" "$here/stubs/gh" "$T/bin/"
chmod +x "$T/bin/git" "$T/bin/gh"
export REAL_GIT PATH=$T/bin:$PATH
unset GITHUB_STEP_SUMMARY KEEPALIVE_DAYS GH_TOKEN

g() { "$REAL_GIT" "$@"; }

fails=0 passes=0
check() {
  local what=$1
  shift
  if "$@"; then
    passes=$((passes + 1))
    printf 'ok   %s: %s\n' "$case_name" "$what"
  else
    fails=$((fails + 1))
    printf 'FAIL %s: %s\n' "$case_name" "$what"
  fi
}

# up_commit FILE CONTENT MESSAGE [TAG]: a commit on upstream's current branch, optionally tagged
up_commit() {
  mkdir -p "$(dirname "$C/up/$1")"
  printf '%s\n' "$2" > "$C/up/$1"
  g -C "$C/up" add -A
  g -C "$C/up" commit -q -m "$3"
  if [ -n "${4:-}" ]; then g -C "$C/up" tag -a "$4" -m "$4"; fi
}

# seed_commit FILE CONTENT MESSAGE: a commit in the seed clone of the fork, on its current branch
seed_commit() {
  printf '%s\n' "$2" > "$C/seed/$1"
  g -C "$C/seed" add -A
  g -C "$C/seed" commit -q -m "$3"
}

# pack commands for the settings: a tarball with or without an npm-shrinkwrap.json ($PACK_* expand inside sync.sh)
# shellcheck disable=SC2016
pack_ok='mkdir -p "$PACK_TMP/package" && cp patch.txt "$PACK_TMP/package/" && printf "{}\n" > "$PACK_TMP/package/npm-shrinkwrap.json" && tar -czf "$PACK_OUT/test-1.0.0.tgz" -C "$PACK_TMP" package'
# shellcheck disable=SC2016
pack_bare='mkdir -p "$PACK_TMP/package" && cp patch.txt "$PACK_TMP/package/" && tar -czf "$PACK_OUT/test-1.0.0.tgz" -C "$PACK_TMP" package'

# new_case NAME [TAG_PATTERN [PACK_CMD]]: upstream with v1.0.0 on main; the fork with drgnx/v1.0.0 = v1.0.0 plus one
# patch commit, released as v1.0.0-drgnx.1
new_case() {
  case_name=$1
  C=$T/$1
  mkdir -p "$C/stub"
  export STUB_LOG=$C/stub DRGNX_SYNC_ENV=$C/sync.env DRGNX_SYNC_OUT=$C/out
  g init -q -b main "$C/up"
  printf 'one\ntwo\n' > "$C/up/a.txt"
  up_commit status.txt ok "init"
  up_commit version.txt 1.0.0 "release 1.0.0" v1.0.0
  g clone -q --bare "$C/up" "$C/fork.git"
  g clone -q "$C/fork.git" "$C/seed"
  g -C "$C/seed" switch -q -c drgnx/v1.0.0 v1.0.0
  printf 'patch\n' > "$C/seed/patch.txt"
  GIT_AUTHOR_NAME="Patch Author" GIT_AUTHOR_EMAIL=patch@example.test seed_commit a.txt "$(printf 'one\ntwo drgnx')" \
    "feat: the drgnx patch"
  g -C "$C/seed" tag v1.0.0-drgnx.1
  g -C "$C/seed" push -q origin drgnx/v1.0.0 v1.0.0-drgnx.1
  # CHECK_CMD's $(...) runs inside sync.sh, not here
  # shellcheck disable=SC2016
  printf 'FORK_REPO=Black-Dragon-Foundation/test\nFORK_URL=%q\nUPSTREAM_URL=%q\nUPSTREAM_BRANCH=main\nTAG_PATTERN=%q\nCHECK_CMD=%q\nPACK_CMD=%q\nNODE_VERSION=22\n' \
    "$C/fork.git" "$C/up" "${2:-^v[0-9]+\.[0-9]+\.[0-9]+\$}" \
    'grep -qx ok status.txt || { echo "status is not ok: $(cat status.txt)"; exit 1; }' "${3:-$pack_ok}" > "$C/sync.env"
}

# run_sync [TAG]: prepare and publish in two fresh clones (two jobs, two runners)
run_sync() {
  (cd "$C" && DRGNX_SYNC_WORK=$C/work1 bash "$sync" prepare test ${1:+"$1"}) > "$C/prepare.log" 2>&1 || {
    echo "prepare exited $?"
    cat "$C/prepare.log"
  }
  (cd "$C" && DRGNX_SYNC_WORK=$C/work2 bash "$sync" publish test ${1:+"$1"}) > "$C/publish.log" 2>&1 || {
    echo "publish exited $?"
    cat "$C/publish.log"
  }
}

result_is() { grep -qx "RESULT=$1" "$C/out/outcome.env" 2> /dev/null; }
pushed() { grep -qF -- "$1" "$C/stub/push.log" 2> /dev/null; }
gh_called() { grep -qF -- "$1" "$C/stub/gh.log" 2> /dev/null; }
body_has() { grep -qF -- "$1" "$C/stub/body.md" 2> /dev/null; }
notes_has() { grep -qF -- "$1" "$C/stub/notes.md" 2> /dev/null; }
no() { ! "$@"; }
# the commit pushed as branch $1
pushed_sha() { sed -n "s|^push origin \([0-9a-f]*\):refs/heads/$1\$|\1|p" "$C/stub/push.log" 2> /dev/null || true; }
in_pub() { g -C "$C/work2" "$@" 2> /dev/null; }
no_force() { ! grep -qE -- '--force|(^| )-f( |$)| \+' "$C/stub/push.log" 2> /dev/null; }
sha_of() { sha256sum "$1" | cut -d ' ' -f 1; }

# 1. a new stable release: our patch replayed onto it as drgnx/v1.1.0, released as v1.1.0-drgnx.1 with the tarball
new_case clean
up_commit b.txt "upstream feature" "feat: b" v1.1.0
up_sha=$(g -C "$C/up" rev-parse 'v1.1.0^{commit}')
run_sync
new=$(pushed_sha drgnx/v1.1.0)
check "outcome ok" result_is ok
check "pushes the branch drgnx/v1.1.0" test -n "$new"
check "its one parent is upstream v1.1.0" test "$(in_pub rev-parse "$new^@")" = "$up_sha"
check "it carries the patch" test "$(in_pub show "$new:patch.txt")" = patch
check "it keeps the patch's edit" test "$(in_pub show "$new:a.txt" | tail -n 1)" = "two drgnx"
check "it has upstream's change" test "$(in_pub show "$new:b.txt")" = "upstream feature"
check "it keeps the patch's message" test "$(in_pub log -1 --format=%s "$new")" = "feat: the drgnx patch"
check "it keeps the patch's author" test "$(in_pub log -1 --format='%an <%ae>' "$new")" = "Patch Author <patch@example.test>"
check "nothing force-pushed" no_force
check "no tag pushed by git (the release makes it)" no pushed "refs/tags/"
check "release v1.1.0-drgnx.1 at the new commit" gh_called "release create v1.1.0-drgnx.1 --repo Black-Dragon-Foundation/test --target $new"
check "release carries the tarball" test -f "$C/stub/assets/test-1.0.0.tgz"
check "release carries its SHA-256" grep -q "$(sha_of "$C/out/pkg/test-1.0.0.tgz")  test-1.0.0.tgz" "$C/stub/assets/test-1.0.0.tgz.sha256"
check "notes give the SHA-256" notes_has "$(sha_of "$C/out/pkg/test-1.0.0.tgz")"
check "main fast-forwarded to upstream" pushed "$up_sha:refs/heads/main"
check "no issue opened" no gh_called "issue create"

# 2. a conflicting release: nothing pushed or released; the issue names the files and the tag
new_case conflict
up_commit a.txt "$(printf 'one\ntwo upstream')" "fix: a" v1.1.0
run_sync
check "outcome conflict" result_is conflict
check "no branch push" no pushed "refs/heads/drgnx/"
check "no release" no gh_called "release create"
check "issue opened" gh_called "issue create"
check "issue names the conflicting file" body_has "a.txt"
check "issue names the upstream tag" body_has "v1.1.0"

# 3. a red check: nothing pushed or released; the issue carries the failing output
new_case red
up_commit status.txt broken "chore: break the check" v1.1.0
run_sync
check "outcome red" result_is red
check "no branch push" no pushed "refs/heads/drgnx/"
check "no release" no gh_called "release create"
check "issue opened" gh_called "issue create"
check "issue has the check output" body_has "status is not ok: broken"
check "issue names the upstream tag" body_has "v1.1.0"
# the issue's by-hand steps, run as written in a clone of the fork, give the tree the job checked
# (the backticks are Markdown fences)
# shellcheck disable=SC2016
{ sed -n '/^```sh$/,/^```$/p' "$C/stub/body.md" 2> /dev/null || true; } | sed '1d;$d' > "$C/recipe.sh"
g clone -q "$C/fork.git" "$C/work3"
(cd "$C/work3" && bash -e "$C/recipe.sh") > "$C/recipe.log" 2>&1 || cat "$C/recipe.log"
check "by-hand steps give the checked tree" \
  test "$(g -C "$C/work3" rev-parse 'drgnx/v1.1.0^{tree}' 2> /dev/null)" = "$(sed -n 's/^TREE=//p' "$C/out/outcome.env")"
check "by-hand steps push the branch" pushed "push origin drgnx/v1.1.0"

# 4. no newer release (an untagged upstream commit): nothing happens
new_case none
up_commit c.txt "work in progress" "feat: c"
run_sync
check "outcome noop" result_is noop
check "no branch push" no pushed "refs/heads/drgnx/"
check "no release" no gh_called "release create"
check "no issue opened" no gh_called "issue create"
check "no issue closed" no gh_called "issue close"

# 5. a pre-release under a stable-only pattern: skipped
new_case prerelease
up_commit b.txt "preview feature" "feat: b" v1.1.0-preview.1
run_sync
check "outcome noop" result_is noop
check "no branch push" no pushed "refs/heads/drgnx/"
check "no release" no gh_called "release create"

# 6. a pattern that follows release candidates: the final release sorts above its rc
new_case candidates '^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
up_commit b.txt "candidate" "feat: b" v1.1.0-rc.1
up_commit b.txt "final" "fix: b" v1.1.0
run_sync
check "outcome ok" result_is ok
check "replays onto the final release" test -n "$(pushed_sha drgnx/v1.1.0)"
check "not onto the candidate" no pushed "refs/heads/drgnx/v1.1.0-rc"

# 7. release tags on sibling release branches (Gemini's): each release bumps the version off main, so a plain merge
# conflicts on version.txt; replaying the patch from the last release's base doesn't
new_case branches
g -C "$C/up" switch -q -c release/v1.1.0 'v1.0.0^'
up_commit b.txt "release feature" "feat: b"
up_commit version.txt 1.1.0 "release 1.1.0" v1.1.0
run_sync
new=$(pushed_sha drgnx/v1.1.0)
check "outcome ok" result_is ok
check "it is v1.1.0 plus the patch, nothing else" in_pub diff --quiet refs/upstream-tags/v1.1.0 "$new" -- . ':!a.txt' ':!patch.txt'
check "it keeps the patch" test "$(in_pub show "$new:a.txt" | tail -n 1)" = "two drgnx"

# 8. many matching tags, more than a pipe buffer of names: an early exit in a tag pipeline would SIGPIPE git
new_case many
v1=$(g -C "$C/up" rev-parse 'v1.0.0^{commit}')
for i in $(seq 1 20000); do printf 'create refs/tags/v0.9.%d %s\n' "$i" "$v1"; done | g -C "$C/up" update-ref --stdin
run_sync
check "outcome noop" result_is noop
check "no branch push" no pushed "refs/heads/drgnx/"

# 9. a release that changes workflow files: the App token can push those, so it goes through like any other
new_case workflows
up_commit .github/workflows/ci.yml "on: push" "ci: change ci" v1.1.0
run_sync
check "outcome ok" result_is ok
check "pushes the branch" test -n "$(pushed_sha drgnx/v1.1.0)"
check "releases it" gh_called "release create v1.1.0-drgnx.1"

# 10. a branch someone pushed by hand (after a conflict): checked, then released at its tip; the branch isn't pushed
new_case tip
up_commit b.txt "upstream feature" "feat: b" v1.1.0
g -C "$C/seed" fetch -q "$C/up" 'refs/tags/v1.1.0:refs/tags/v1.1.0'
g -C "$C/seed" switch -q -c drgnx/v1.1.0 v1.1.0
g -C "$C/seed" cherry-pick drgnx/v1.0.0 > /dev/null
tip=$(g -C "$C/seed" rev-parse HEAD)
g -C "$C/seed" push -q origin drgnx/v1.1.0
run_sync
check "outcome ok" result_is ok
check "no branch push" no pushed "refs/heads/drgnx/"
check "release v1.1.0-drgnx.1 at the branch tip" gh_called "release create v1.1.0-drgnx.1 --repo Black-Dragon-Foundation/test --target $tip"

# 11. a later patch fix on the same release: a new tag -drgnx.2, never a moved one
new_case fix
g -C "$C/seed" switch -q drgnx/v1.0.0
seed_commit fix.txt fixed "fix: the patch"
fixed=$(g -C "$C/seed" rev-parse HEAD)
g -C "$C/seed" push -q origin drgnx/v1.0.0
run_sync
check "outcome ok" result_is ok
check "release v1.0.0-drgnx.2 at the fix" gh_called "release create v1.0.0-drgnx.2 --repo Black-Dragon-Foundation/test --target $fixed"
check "no branch push" no pushed "refs/heads/drgnx/"

# 12. a released fix is part of the patch: the next replay squashes the branch into one commit
new_case squash
g -C "$C/seed" switch -q drgnx/v1.0.0
seed_commit fix.txt fixed "fix: the patch"
g -C "$C/seed" tag v1.0.0-drgnx.2
g -C "$C/seed" push -q origin drgnx/v1.0.0 v1.0.0-drgnx.2
up_commit b.txt "upstream feature" "feat: b" v1.1.0
up_sha=$(g -C "$C/up" rev-parse 'v1.1.0^{commit}')
run_sync
new=$(pushed_sha drgnx/v1.1.0)
check "outcome ok" result_is ok
check "one commit on top of v1.1.0" test "$(in_pub rev-parse "$new^")" = "$up_sha"
check "it has the fix" test "$(in_pub show "$new:fix.txt")" = fixed
check "it has the patch's message" test "$(in_pub log -1 --format=%s "$new")" = "feat: the drgnx patch"

# 13. a tarball without npm-shrinkwrap.json is red
new_case noshrinkwrap '' "$pack_bare"
up_commit b.txt "upstream feature" "feat: b" v1.1.0
run_sync
check "outcome red" result_is red
check "no branch push" no pushed "refs/heads/drgnx/"
check "no release" no gh_called "release create"
check "issue names the missing shrinkwrap" body_has "npm-shrinkwrap.json"

# 14. a named release (DeepSeek's pins are moved by hand): that one, not the newest
new_case named
up_commit b.txt "feature" "feat: b" v1.1.0
up_commit c.txt "later" "feat: c" v1.2.0
run_sync v1.1.0
check "outcome ok" result_is ok
check "replays onto v1.1.0" test -n "$(pushed_sha drgnx/v1.1.0)"
check "not onto v1.2.0" no pushed "refs/heads/drgnx/v1.2.0"

# 15. an open sync issue is updated, not duplicated
new_case update
up_commit a.txt "$(printf 'one\ntwo upstream')" "fix: a" v1.1.0
printf '7\n' > "$C/stub/open-issue"
printf 'blocked at an older release\n' > "$C/stub/issue-body"
run_sync
check "no second issue" no gh_called "issue create"
check "issue 7 edited" gh_called "issue edit 7"
check "issue 7 commented" gh_called "issue comment 7"
check "edited body names the tag" body_has "v1.1.0"

# 16. the same block already reported: the issue is left alone
new_case reported
up_commit a.txt "$(printf 'one\ntwo upstream')" "fix: a" v1.1.0
printf '7\n' > "$C/stub/open-issue"
printf 'old text\n<!-- drgnx-sync: conflict v1.1.0 -->\n' > "$C/stub/issue-body"
run_sync
check "no edit" no gh_called "issue edit"
check "no comment" no gh_called "issue comment"

# 17. the release was handled: the next run closes the open issue
new_case resolved
printf '7\n' > "$C/stub/open-issue"
run_sync
check "outcome noop" result_is noop
check "issue 7 closed" gh_called "issue close 7"

# 18. keep-alive for this repo's schedule: an empty commit after KEEPALIVE_DAYS without one
case_name=keepalive
C=$T/keepalive
mkdir -p "$C/stub"
export STUB_LOG=$C/stub
g init -q -b main "$C/repo"
g -C "$C/repo" commit -q --allow-empty -m "init"
(cd "$C/repo" && bash "$sync" keepalive) > "$C/ka.log" 2>&1 || cat "$C/ka.log"
check "nothing pushed while the repo is active" no pushed "refs/heads/main"
(cd "$C/repo" && KEEPALIVE_DAYS=0 bash "$sync" keepalive) > "$C/ka.log" 2>&1 || cat "$C/ka.log"
check "empty commit pushed once it is quiet" pushed "HEAD:refs/heads/main"
check "the commit is empty" test "$(g -C "$C/repo" rev-parse 'HEAD^{tree}')" = "$(g -C "$C/repo" rev-parse 'HEAD~1^{tree}')"

printf '%d passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
