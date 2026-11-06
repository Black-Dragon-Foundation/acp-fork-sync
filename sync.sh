#!/usr/bin/env bash
# acp-fork-sync: carry drgnx's patch onto each new upstream release of an ACP adapter fork, check it, and release it.
#
#   sync.sh settings FORK        print node_version=... (GITHUB_OUTPUT form) for the workflow
#   sync.sh prepare FORK [TAG]   plan, then check and pack the result; write the outcome to $DRGNX_SYNC_OUT.
#                                Runs upstream's code, so the workflow gives this job no secrets and a read-only token.
#   sync.sh publish FORK [TAG]   plan again and match it to the outcome; then push the new branch and create the
#                                release with the package and its SHA-256, or open/update the fork's sync issue.
#                                Runs no upstream code. Pushes with $GH_TOKEN (the GitHub App's token).
#   sync.sh keepalive            an empty commit on this repo's main once it has had none for KEEPALIVE_DAYS (GitHub
#                                turns off a public repo's schedules after 60 days without activity)
#
# FORK names forks/FORK.env (or $DRGNX_SYNC_ENV). TAG picks an upstream release instead of the newest one matching
# TAG_PATTERN; manual runs (DeepSeek) use it.
#
# The fork keeps one branch per upstream release, drgnx/<tag> = <tag> plus our patch, released as <tag>-drgnx.<n>.
# Nothing is ever force-pushed, and no tag is ever moved. For the release T:
#   - no drgnx/T: replay the patch from drgnx/S, S the highest release below T that has a branch, onto T as one
#     commit (the patch's message and author). The merge base is S itself, not git's common ancestor, so upstreams
#     that cut each release on its own branch (Gemini) don't conflict on every version bump.
#   - drgnx/T with an unreleased tip (pushed by hand after a conflict, or a later fix): check and release the tip as
#     the next <n>.
#   - drgnx/T released at its tip: nothing to do.
# Outcomes: noop, ok, conflict, red (checks or package failed). A conflict or red pushes nothing.
#
# Settings (sourced as bash): FORK_REPO (owner/name), FORK_URL (default https://github.com/FORK_REPO), UPSTREAM_URL,
# UPSTREAM_BRANCH (mirrored to the fork's branch of that name; default main), TAG_PATTERN (extended regexp),
# CHECK_CMD and PACK_CMD (bash, run at the fork's root; PACK_CMD writes one .tgz with an npm-shrinkwrap.json into
# $PACK_OUT and may use $PACK_TMP and $SYNC_HOME; empty means no package), NODE_VERSION.
#
# The issue text is Markdown: its backticks in single quotes are literal on purpose.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cmd=${1:-}
fork=${2:-}
want=${3:-}
KEEPALIVE_DAYS=${KEEPALIVE_DAYS:-50}
ISSUE_TITLE="drgnx sync blocked"
export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-github-actions[bot]}
export GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}
export GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}

say() { printf 'acp-fork-sync: %s\n' "$*" >&2; }
die() {
  say "error: $*"
  exit 1
}
note() {
  say "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

load_settings() {
  [ -n "$fork" ] || die "usage: sync.sh settings|prepare|publish FORK [TAG]"
  # shellcheck source=/dev/null
  . "${DRGNX_SYNC_ENV:-$here/forks/$fork.env}"
  : "${FORK_REPO:?settings must set FORK_REPO}" "${UPSTREAM_URL:?settings must set UPSTREAM_URL}"
  : "${TAG_PATTERN:?settings must set TAG_PATTERN}" "${CHECK_CMD:?settings must set CHECK_CMD}"
  FORK_URL=${FORK_URL:-https://github.com/$FORK_REPO}
  UPSTREAM_BRANCH=${UPSTREAM_BRANCH:-main}
  PACK_CMD=${PACK_CMD:-}
  NODE_VERSION=${NODE_VERSION:-22}
  OUT=${DRGNX_SYNC_OUT:-${RUNNER_TEMP:-/tmp}/drgnx-sync}
  WORK=${DRGNX_SYNC_WORK:-${RUNNER_TEMP:-/tmp}/drgnx-fork}
}

# A fresh clone of the fork, with upstream's tags under refs/upstream-tags/ and its branch under refs/upstream/.
open_fork() {
  [ ! -e "$WORK" ] || die "$WORK already exists"
  git clone --quiet --no-checkout "$FORK_URL" "$WORK"
  cd "$WORK"
  git fetch --quiet --no-tags "$UPSTREAM_URL" '+refs/tags/*:refs/upstream-tags/*' \
    "+refs/heads/$UPSTREAM_BRANCH:refs/upstream/$UPSTREAM_BRANCH"
}

# Upstream's release tags, highest version first. versionsort.suffix=- sorts 1.2.0-rc.1 before 1.2.0. The list is
# read whole before filtering: an early exit in a pipeline (head, break) would SIGPIPE git under pipefail.
release_tags() {
  local all
  all=$(git -c versionsort.suffix=- for-each-ref --sort=-version:refname --format='%(refname:lstrip=2)' \
    refs/upstream-tags/)
  printf '%s\n' "$all" | grep -E -- "$TAG_PATTERN" || true
}

tag_commit() { git rev-parse --verify --quiet "refs/upstream-tags/$1^{commit}"; }
branch_sha() { git rev-parse --verify --quiet "refs/remotes/origin/drgnx/$1"; }

# released TAG COMMIT: COMMIT carries a TAG-drgnx.<n> tag
released() {
  local t n
  for t in $(git tag --points-at "$2"); do
    n=${t#"$1-drgnx."}
    if [ "$n" != "$t" ] && [[ $n =~ ^[0-9]+$ ]]; then return 0; fi
  done
  return 1
}

# next_n TAG: one more than the highest TAG-drgnx.<n> in the fork
next_n() {
  local t n max=0
  for t in $(git tag -l "$1-drgnx.*"); do
    n=${t#"$1-drgnx."}
    if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt "$max" ]; then max=$n; fi
  done
  printf '%s\n' $((max + 1))
}

# plan: decide what to do for the release, from the fork's branches and tags and upstream's tags. Sets MODE (noop,
# replay, tip, conflict), TAG, TAG_SHA, SOURCE (the commit carrying the patch: drgnx/S's tip, or drgnx/T's tip),
# SBASE (S's commit, for a replay), TREE (the result's tree) and CONFLICTS.
plan() {
  local tags t seen='' tip mt
  tags=$(release_tags)
  TAG=${want:-${tags%%$'\n'*}}
  MODE=noop TAG_SHA='' SOURCE='' SBASE='' TREE='' CONFLICTS=''
  [ -n "$TAG" ] || return 0
  printf '%s\n' "$TAG" | grep -qE -- "$TAG_PATTERN" || die "$TAG doesn't match TAG_PATTERN"
  TAG_SHA=$(tag_commit "$TAG") || die "upstream has no tag $TAG"
  if tip=$(branch_sha "$TAG"); then
    git merge-base --is-ancestor "$TAG_SHA" "$tip" || die "drgnx/$TAG doesn't start at upstream $TAG"
    SOURCE=$tip
    if ! released "$TAG" "$tip"; then
      MODE=tip
      TREE=$(git rev-parse "$tip^{tree}")
    fi
    return 0
  fi
  for t in $tags; do
    if [ -z "$seen" ]; then
      if [ "$t" = "$TAG" ]; then seen=1; fi
      continue
    fi
    if SOURCE=$(branch_sha "$t"); then
      SBASE=$(tag_commit "$t")
      break
    fi
  done
  [ -n "$SOURCE" ] || die "no drgnx/<release> branch below $TAG to carry the patch from"
  if mt=$(git merge-tree --write-tree --name-only --no-messages --merge-base="$SBASE" "$SOURCE" "$TAG_SHA"); then
    MODE=replay
    TREE=$mt
  else
    [ $? -eq 1 ] || die "git merge-tree failed"
    MODE=conflict
    CONFLICTS=$(printf '%s\n' "$mt" | tail -n +2)
  fi
}

# The first commit of the patch on drgnx/S: its message and author go on the replayed commit.
patch_commit() {
  local all
  all=$(git rev-list --reverse --first-parent "$SBASE..$SOURCE")
  printf '%s\n' "${all%%$'\n'*}"
}

replay_commit() {
  local p
  p=$(patch_commit)
  git log -1 --format=%B "$p" |
    GIT_AUTHOR_NAME=$(git log -1 --format=%an "$p") GIT_AUTHOR_EMAIL=$(git log -1 --format=%ae "$p") \
      GIT_AUTHOR_DATE=$(git log -1 --format=%aI "$p") git commit-tree "$TREE" -p "$TAG_SHA"
}

write_outcome() { # RESULT [PKG]
  printf 'RESULT=%s\nMODE=%s\nTAG=%s\nTAG_SHA=%s\nSOURCE=%s\nTREE=%s\nPKG=%s\n' \
    "$1" "$MODE" "$TAG" "$TAG_SHA" "$SOURCE" "$TREE" "${2:-}" > "$OUT/outcome.env"
  note "$fork: $1${TAG:+ for upstream $TAG}${MODE:+ ($MODE)}"
}

# run_logged NAME CMD [VAR=VALUE...]: run CMD (bash) with the variables, its output appended to the log; the log then
# says how it ended, so the issue can show the command's own status and error
run_logged() {
  local name=$1 cmd=$2 st
  shift 2
  st=0
  env "$@" bash -c "$cmd" 2>&1 | tee -a "$OUT/check.log" || st=${PIPESTATUS[0]}
  [ "$st" -eq 0 ] || printf 'acp-fork-sync: %s exited with status %s\n' "$name" "$st" | tee -a "$OUT/check.log"
  return "$st"
}

# pack: run PACK_CMD; it must leave exactly one tarball, and that tarball must hold npm-shrinkwrap.json
pack() {
  local tmp pkgs
  tmp=$(mktemp -d)
  run_logged PACK_CMD "$PACK_CMD" PACK_OUT="$OUT/pkg" PACK_TMP="$tmp" SYNC_HOME="$here" || return 1
  pkgs=$(find "$OUT/pkg" -maxdepth 1 -name '*.tgz')
  if [ -z "$pkgs" ] || [ "$(printf '%s\n' "$pkgs" | wc -l)" -ne 1 ]; then
    printf 'acp-fork-sync: PACK_CMD must write exactly one .tgz into $PACK_OUT\n' | tee -a "$OUT/check.log"
    return 1
  fi
  tar -tzf "$pkgs" > "$tmp/list"
  if ! grep -qx 'package/npm-shrinkwrap.json' "$tmp/list"; then
    printf 'acp-fork-sync: %s has no package/npm-shrinkwrap.json\n' "${pkgs##*/}" | tee -a "$OUT/check.log"
    return 1
  fi
  PKG=${pkgs##*/}
}

prepare() {
  local commit
  load_settings
  mkdir -p "$OUT/pkg"
  rm -f "$OUT/outcome.env" "$OUT/check.log" "$OUT"/pkg/*.tgz
  : > "$OUT/check.log"
  open_fork
  plan
  case "$MODE" in
    noop)
      write_outcome noop
      return
      ;;
    conflict)
      printf '%s\n' "$CONFLICTS" | sed 's/^/conflict: /' >&2
      write_outcome conflict
      return
      ;;
    replay) commit=$(replay_commit) ;;
    tip) commit=$SOURCE ;;
  esac
  git switch --quiet --detach "$commit"
  say "checking upstream $TAG with the patch ($MODE)"
  PKG=''
  if run_logged CHECK_CMD "$CHECK_CMD" && { [ -z "$PACK_CMD" ] || pack; }; then
    write_outcome ok "$PKG"
  else
    write_outcome red
  fi
}

# The outcome comes from the job that ran upstream's code, so it is parsed and checked, never sourced.
read_outcome() {
  local k v
  O_RESULT='' O_MODE='' O_TAG='' O_TAG_SHA='' O_SOURCE='' O_TREE='' O_PKG=''
  [ -f "$OUT/outcome.env" ] || die "no outcome in $OUT"
  while IFS='=' read -r k v; do
    case "$k" in RESULT | MODE | TAG | TAG_SHA | SOURCE | TREE | PKG) printf -v "O_$k" '%s' "$v" ;; esac
  done < "$OUT/outcome.env"
  case "$O_RESULT" in noop | ok | conflict | red) ;; *) die "unknown outcome '$O_RESULT'" ;; esac
  case "$O_PKG" in '' | [A-Za-z0-9@]*.tgz) ;; *) die "bad package name in the outcome" ;; esac
  case "$O_PKG" in */* | *..*) die "bad package name in the outcome" ;; esac
}

push_auth() {
  [ -n "${GH_TOKEN:-}" ] || return 0
  git config --local --replace-all credential.helper ''
  git config --local --add credential.helper \
    '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; }; f'
}

issue_number() {
  gh issue list --repo "$FORK_REPO" --state open --limit 100 --json number,title \
    --jq ".[] | select(.title | startswith(\"$ISSUE_TITLE\")) | .number" | head -n 1
}

close_issue() { # MESSAGE
  local n
  n=$(issue_number)
  if [ -n "$n" ]; then gh issue close "$n" --repo "$FORK_REPO" --comment "$1"; fi
}

manual_steps() {
  if [ "$MODE" = tip ]; then
    printf 'Fix it on `drgnx/%s` with a new commit (never a force-push) and push the branch. ' "$TAG"
    printf 'The next run checks the new tip and releases it as `%s-drgnx.<n>`.\n' "$TAG"
    return
  fi
  printf 'To carry the patch by hand, the way the job does (the changes on `drgnx/<previous release>` since that '
  printf 'release, applied to %s), from a clone of the fork:\n\n```sh\n' "$TAG"
  printf 'git fetch %s "refs/tags/%s:refs/upstream-tags/%s"\n' "$UPSTREAM_URL" "$TAG" "$TAG"
  printf 'git switch -c "drgnx/%s" "refs/upstream-tags/%s^{commit}"\n' "$TAG" "$TAG"
  printf 'git diff --binary %s %s | git apply --3way --index\n' "$SBASE" "$SOURCE"
  printf '# resolve any conflicts and `git add` them, then:\n'
  printf 'git commit --quiet -C %s\n' "$(patch_commit)"
  printf '# run the checks (CHECK_CMD in acp-fork-sync/forks/%s.env), then:\n' "$fork"
  printf 'git push origin "drgnx/%s"\n' "$TAG"
  printf '```\n\nThe next run checks the branch, releases it as `%s-drgnx.1` and closes this issue.\n' "$TAG"
}

# failure_excerpt: the exit status line and the lines around the first error of the log (the last lines when none looks
# like an error; the noise after an error is mostly its consequences)
failure_excerpt() {
  local clean first
  clean=$OUT/check.clean.log
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$OUT/check.log" > "$clean" 2> /dev/null || : > "$clean"
  grep -E '^acp-fork-sync: [A-Z_]+ exited with status' "$clean" | tail -n 1 || true
  first=$(grep -niE '(^|[^[:alnum:]_.-])(npm error|npm err!|error[:!]|fatal[:!]|failed|FAIL )|command not found|: not found|ERR_[A-Z_]+' "$clean" |
    grep -v 'acp-fork-sync: ' | head -n 1 | cut -d: -f1) || true
  if [ -n "$first" ]; then
    sed -n "$((first > 20 ? first - 20 : 1)),$((first + 30))p" "$clean" | tail -c 20000
  else
    tail -n 80 "$clean" | tail -c 20000
  fi
}

issue_body() { # MARKER
  printf 'Upstream release **%s** (`%s`) has no drgnx release yet, and nothing was pushed.\n\n' "$TAG" "$TAG_SHA"
  case "$O_RESULT" in
    conflict)
      printf 'The patch from `%s` conflicts with it in:\n\n' "$SOURCE"
      printf '%s\n' "$CONFLICTS" | sed 's/^/- `/; s/$/`/'
      ;;
    red)
      printf 'The patch applies, but the checks or the package failed (CHECK_CMD, PACK_CMD in '
      printf '`acp-fork-sync/forks/%s.env`). The failing command'"'"'s own error:\n\n````text\n' "$fork"
      failure_excerpt
      printf '\n````\n'
      ;;
  esac
  printf '\n'
  manual_steps
  printf '\n%s\n' "$1"
}

report() {
  local marker n f
  marker="<!-- drgnx-sync: $O_RESULT $TAG -->"
  f=$OUT/issue.md
  issue_body "$marker" > "$f"
  n=$(issue_number)
  if [ -z "$n" ]; then
    gh issue create --repo "$FORK_REPO" --title "$ISSUE_TITLE: upstream $TAG" --body-file "$f"
  elif gh issue view "$n" --repo "$FORK_REPO" --json body --jq .body | grep -qF -- "$marker"; then
    say "issue #$n already reports $O_RESULT for $TAG"
  else
    gh issue edit "$n" --repo "$FORK_REPO" --title "$ISSUE_TITLE: upstream $TAG" --body-file "$f"
    gh issue comment "$n" --repo "$FORK_REPO" --body "Now blocked at upstream $TAG ($O_RESULT); the description has the details."
  fi
  note "$fork: not released: upstream $TAG ($O_RESULT); reported in the sync issue"
}

release() {
  local commit n t pkg sum assets=()
  n=$(next_n "$TAG")
  t=$TAG-drgnx.$n
  if [ "$MODE" = replay ]; then
    commit=$(replay_commit)
    git push origin "$commit:refs/heads/drgnx/$TAG"
  else
    commit=$SOURCE
  fi
  {
    printf 'drgnx'"'"'s patch on upstream %s (`%s`): commit `%s` on `drgnx/%s`.\n\n' "$TAG" "$TAG_SHA" "$commit" "$TAG"
    if [ -n "$O_PKG" ]; then
      pkg=$OUT/pkg/$O_PKG
      [ -f "$pkg" ] || die "the outcome names $O_PKG, but the artifact has no such file"
      sum=$(sha256sum "$pkg" | cut -d ' ' -f 1)
      printf '%s  %s\n' "$sum" "$O_PKG" > "$pkg.sha256"
      assets=("$pkg" "$pkg.sha256")
      printf 'Package `%s` (with its npm-shrinkwrap.json), SHA-256 `%s`.\n' "$O_PKG" "$sum"
    else
      printf 'No package is built for this fork.\n'
    fi
  } > "$OUT/notes.md"
  # The release creates the tag at COMMIT. If it fails after a replay, drgnx/TAG exists with an unreleased tip, and
  # the next run releases it.
  gh release create "$t" --repo "$FORK_REPO" --target "$commit" --title "$t" --notes-file "$OUT/notes.md" \
    ${assets[@]+"${assets[@]}"}
  note "$fork: released $t at $commit"
  close_issue "Released \`$t\` (commit $commit)."
}

mirror_upstream_branch() {
  local up cur
  up=$(git rev-parse "refs/upstream/$UPSTREAM_BRANCH")
  cur=$(git rev-parse --verify --quiet "refs/remotes/origin/$UPSTREAM_BRANCH") || cur=''
  [ "$up" != "$cur" ] || return 0
  if [ -n "$cur" ] && ! git merge-base --is-ancestor "$cur" "$up"; then
    note "$fork: warning: $UPSTREAM_BRANCH has diverged from upstream; not mirrored"
  else
    git push origin "$up:refs/heads/$UPSTREAM_BRANCH"
  fi
}

publish() {
  load_settings
  read_outcome
  open_fork
  plan
  # the same plan as prepare's, so the result is the tree that was checked
  [ "$MODE|$TAG|$TAG_SHA|$SOURCE|$TREE" = "$O_MODE|$O_TAG|$O_TAG_SHA|$O_SOURCE|$O_TREE" ] ||
    die "the fork or upstream changed since prepare; the next run retries"
  push_auth
  case "$O_RESULT" in
    noop)
      if [ -n "$TAG" ]; then close_issue "\`drgnx/$TAG\` is released at its tip."; fi
      note "$fork: up to date${TAG:+ with upstream $TAG}"
      ;;
    ok) release ;;
    conflict | red) report ;;
  esac
  mirror_upstream_branch
  # a blocked fork makes the run red, after the issue says why, so a skipped release can't hide behind a green run
  case "$O_RESULT" in conflict | red) die "$fork: blocked at upstream $TAG ($O_RESULT); no release" ;; esac
}

keepalive() {
  local last
  last=$(git log -1 --format=%ct HEAD)
  if [ $(($(date +%s) - last)) -lt $((KEEPALIVE_DAYS * 86400)) ]; then
    say "last commit is newer than $KEEPALIVE_DAYS days; no keep-alive needed"
    return 0
  fi
  git commit --quiet --allow-empty -m "ci: keep the scheduled sync alive"
  git push origin HEAD:refs/heads/main
}

case "$cmd" in
  settings)
    load_settings
    printf 'node_version=%s\n' "$NODE_VERSION"
    ;;
  prepare) prepare ;;
  publish) publish ;;
  keepalive) keepalive ;;
  *) die "usage: sync.sh settings|prepare|publish FORK [TAG], or sync.sh keepalive" ;;
esac
