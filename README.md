# acp-fork-sync

Keeps drgnx's forks of the ACP adapters on their upstreams' releases. Every day, for each fork, it:
1. takes upstream's newest stable release;
2. carries drgnx's patch onto it as a new branch;
3. checks it, packs it, and publishes a GitHub release with the package and its SHA-256.

When the patch doesn't apply or a check fails, it pushes nothing and opens an issue in the fork.

| Fork | Upstream | Follows | Schedule |
|---|---|---|---|
| [claude-agent-acp](https://github.com/Black-Dragon-Foundation/claude-agent-acp) | agentclientprotocol/claude-agent-acp | `vX.Y.Z` | daily |
| [gemini-cli](https://github.com/Black-Dragon-Foundation/gemini-cli) | google-gemini/gemini-cli | `vX.Y.Z` (no preview, nightly) | daily |
| [kimi-code](https://github.com/Black-Dragon-Foundation/kimi-code) | MoonshotAI/kimi-code | `@moonshot-ai/kimi-code@X.Y.Z` (no canary) | daily |
| [deepseek-harness](https://github.com/Black-Dragon-Foundation/deepseek-harness) | deepseek-ai/deepseek-harness | `dsh-vX.Y.Z[-rc.N]`, the one drgnx pins | by hand |

## The forks' layout

- **`drgnx/<tag>`**: upstream's release `<tag>` plus one commit, drgnx's patch. There is one branch per release
  and it is never rewritten. The patch's own notes live in `DRGNX-CHANGES.md`, never in upstream's `CHANGELOG.md`,
  so releases don't conflict on the changelog.
- **`<tag>-drgnx.<n>`**: the release drgnx pins, created by the GitHub release, at the branch's tip. A later fix on
  the same upstream release is a new commit on `drgnx/<tag>` and a new `<tag>-drgnx.<n+1>`. A tag is never moved.
- **The release's assets:** the package tarball (with an `npm-shrinkwrap.json`, so its dependencies are locked)
  and `<tarball>.sha256`. drgnx installs the tarball by its checksum.
- **The upstream's default branch** (`main`, or DeepSeek's `master`) mirrors upstream (fast-forward only).

Nothing is ever force-pushed. Every commit drgnx has pinned stays reachable on its branch.

## How a run works

`.github/workflows/sync.yml` runs daily at 04:23 UTC and on demand (`workflow_dispatch`). It has three jobs.

**`check`**, one per fork, with no secrets and a read-only token (`sync.sh prepare FORK`):
1. It clones the fork and fetches upstream's tags, then picks the newest release `T` that matches the fork's
   `TAG_PATTERN`.
2. It plans from the fork's branches and tags:
   - **no `drgnx/T`**: it replays the patch from `drgnx/S`, the highest release below `T` that has a branch. The
     replay is one commit on `T` that keeps the patch's message and author. Its merge base is `S` itself, not git's
     common ancestor, so an upstream that cuts each release on its own branch doesn't conflict on every version
     bump. Gemini does this: `v0.66.0` is not an ancestor of `v0.67.0`, and a plain merge conflicts on nine
     `package.json` files and the lockfile.
   - **`drgnx/T` with an unreleased tip** (pushed by hand after a conflict, or a fix): it takes the tip.
   - **`drgnx/T` released at its tip**: nothing to do.
3. It runs the fork's `CHECK_CMD` (install from the lockfile, type-check, lint, the patch's tests) and its
   `PACK_CMD`. The tarball must hold `package/npm-shrinkwrap.json`.
4. It uploads the outcome (`noop`, `ok`, `conflict` or `red`), the log and the tarball as an artifact.

This job runs upstream's code, which is why it holds nothing worth stealing.

**`publish`**, one per fork (`sync.sh publish FORK`), runs only this repo's script:
1. It plans again from the fork and upstream, and refuses unless the plan matches the checked outcome: the same
   mode, tag, source commit and tree. The outcome file is parsed and checked, never sourced.
2. It mints a GitHub App token scoped to that one fork, with contents, workflows and issues write.
3. Then, by outcome:
   - **`ok`**: it pushes the new branch (for a replay), then creates the release `<tag>-drgnx.<n>` at the commit
     with the tarball and its `.sha256`, and closes the fork's sync issue. If creating the release fails after the
     push, the branch is left with an unreleased tip, and the next run releases it.
   - **`conflict`, `red`**: it pushes nothing. It opens the fork's issue "drgnx sync blocked: upstream `<tag>`",
     or updates it with an edit and a comment. The issue carries the conflicting files or the failing command's exit status and
     the lines around its first error, and the exact commands to carry the patch by hand. A block that's already
     reported is left alone. The job then fails, after the issue is written, so a skipped release shows as a red run.
4. Last, it fast-forwards the fork's upstream branch.

Workflow-file changes push like any other, because the App token holds the workflows permission.

**`keepalive`** (`sync.sh keepalive`): GitHub turns off a public repository's schedules after 60 days without
activity. Once this repo has had no commit for 50 days, the job pushes an empty commit with its own `GITHUB_TOKEN`
(contents write on this repo only).

## Setup

All of this needs an org owner. The forks keep GitHub Actions **off**: no workflow runs there, and upstream's own
publish and release workflows stay inert.

### 1. This repository

```sh
gh repo create Black-Dragon-Foundation/acp-fork-sync --public --source . --remote origin --push
R=Black-Dragon-Foundation/acp-fork-sync
gh api -X PUT repos/$R/actions/permissions -F enabled=true -f allowed_actions=selected
gh api -X PUT repos/$R/actions/permissions/selected-actions -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT repos/$R/actions/permissions/workflow -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```

Only GitHub's own actions are allowed (`actions/*`, which includes `actions/create-github-app-token`), each pinned
to a commit.

### 2. The GitHub App

GitHub has no CLI for creating an App. In the browser, open
<https://github.com/organizations/Black-Dragon-Foundation/settings/apps/new> and set:

- **Name** `drgnx-fork-sync`, **Homepage URL** this repository's URL, **Webhook**: off (clear "Active").
- **Repository permissions**:
  - Contents: Read and write
  - Workflows: Read and write
  - Issues: Read and write
  - Metadata: Read-only (always required)
  - nothing else.
- **Where can this GitHub App be installed?** Only on this account.

Then:
1. Create the App and note its **App ID**.
2. **Generate a private key**; it downloads a `.pem` file.
3. **Install App**, on Black-Dragon-Foundation, **Only select repositories**: `claude-agent-acp`, `gemini-cli`,
   `kimi-code`, `deepseek-harness`.

Store the two secrets in this repository and delete the downloaded key:

```sh
gh secret set DRGNX_SYNC_APP_ID  -R Black-Dragon-Foundation/acp-fork-sync --body "<App ID>"
gh secret set DRGNX_SYNC_APP_KEY -R Black-Dragon-Foundation/acp-fork-sync < path/to/the-key.pem
rm path/to/the-key.pem
```

The workflow asks for a token per run, per fork, and it expires within the hour.

### 3. The forks

claude-agent-acp exists already. Create the others:

```sh
gh repo fork MoonshotAI/kimi-code           --org Black-Dragon-Foundation --clone=false --default-branch-only
# Gemini and DeepSeek: all branches, since their release tags sit off the default branch
gh repo fork google-gemini/gemini-cli       --org Black-Dragon-Foundation --clone=false
gh repo fork deepseek-ai/deepseek-harness   --org Black-Dragon-Foundation --clone=false
```

For each fork `F` (`Black-Dragon-Foundation/<name>`), turn issues on and Actions off:

```sh
gh repo edit $F --enable-issues
gh api -X PUT repos/$F/actions/permissions -F enabled=false
```

Then push the first patch branch from the clone that has it (remote `org` = `git@github.com:$F.git`):

```sh
git -C claude-agent-acp push org drgnx/v0.101.0
git -C gemini-cli       push org drgnx/v0.67.0
git -C kimi-code        push org drgnx/@moonshot-ai/kimi-code@2.5.2
git -C deepseek-harness push org drgnx/dsh-v0.2.2-rc.1
```

Each is upstream's release plus one squashed patch commit. The first scheduled run, or
`gh workflow run sync.yml -R Black-Dragon-Foundation/acp-fork-sync`, finds the unreleased tips and releases
`v0.101.0-drgnx.1`, `v0.67.0-drgnx.1` and `@moonshot-ai/kimi-code@2.5.2-drgnx.1`. DeepSeek's first release is a
manual run (below).

## DeepSeek by hand

DeepSeek Harness is a developer preview with promised breaks, so drgnx pins one exact pre-release, and moving the
pin is a decision. Pass the tag to move to. Run the checks in a container, since they run upstream's code. The
publish step runs only git and gh, with your own login.

```sh
TAG=dsh-v0.2.3-rc.1
mkdir -p .out
podman run --rm --memory 3g --memory-swap 3g --cpus 4 -v "$PWD:/sync:Z" -w /sync \
  -e DRGNX_SYNC_OUT=/sync/.out -e DRGNX_SYNC_WORK=/tmp/fork \
  docker.io/library/node:24 bash sync.sh prepare deepseek-harness "$TAG"
GH_TOKEN=$(gh auth token) DRGNX_SYNC_OUT="$PWD/.out" DRGNX_SYNC_WORK="$(mktemp -d)/fork" \
  bash sync.sh publish deepseek-harness "$TAG"
```

For the first release, pass the base the branch already has: `TAG=dsh-v0.2.2-rc.1`. Your `gh` login needs the
`workflow` scope (`gh auth refresh -s workflow`) if the release changes workflow files. DeepSeek's releases carry no
package yet: `@deepseek-ai/dsh-acp` depends on workspace packages that aren't on npm, so it needs a bundle first.

## Settings

`forks/<fork>.env`, sourced by `sync.sh`:

| Setting | Meaning |
|---|---|
| `FORK_REPO` | `owner/name` of the fork (`FORK_URL` defaults to its GitHub URL) |
| `UPSTREAM_URL`, `UPSTREAM_BRANCH` | upstream's clone URL and default branch |
| `TAG_PATTERN` | extended regexp a release tag must match |
| `CHECK_CMD` | bash, at the fork's root: install, type-check, lint, the patch's tests (vitest with `--maxWorkers=2`) |
| `PACK_CMD` | bash: write one `.tgz` holding `npm-shrinkwrap.json` into `$PACK_OUT` (scratch: `$PACK_TMP`) |
| `NODE_VERSION` | Node.js for the checks |

How each fork packs:
- **claude-agent-acp**: a single package. Its own lockfile becomes the shrinkwrap, so users get the versions that
  were tested.
- **gemini-cli**: the root bundle (CLI and core with the patch, as upstream ships it).
- **kimi-code**: the CLI package.

The last two are packed in a monorepo, so `pack-shrinkwrap.sh` repacks them with a shrinkwrap resolved from the
registry at build time. When a package lists `files`, npm leaves `npm-shrinkwrap.json` out unless it is listed, so
both paths add it.

## Tests

```sh
bash test/sync-test.sh
```

It needs bash, git ≥ 2.40, tar and coreutils: no Node, no network, no GitHub. Each case builds a fake upstream and a
fake fork in a temp folder, and runs `prepare` and `publish` in separate clones. `git push` and `gh` are stubs that
only log. The cases:

- a clean replay: one commit on the new tag, with the patch's message and author, the release with the tarball
  and its SHA-256, and the upstream branch mirrored;
- a conflict and a red check open the issue and push nothing, and the issue's by-hand steps reproduce the
  checked tree;
- no newer tag, or only a pre-release, does nothing;
- a release candidate pattern ranks the final release above its rc;
- Gemini-style release branches replay cleanly;
- 20000 matching tags work;
- a workflow-file change pushes;
- a hand-pushed branch is released at its tip;
- a fix on a released branch gets `-drgnx.2`;
- a fixed branch is squashed on the next replay;
- a tarball without a shrinkwrap is red; a failing `prepare` script doesn't stop the repack;
- a blocked fork fails the publish job; the issue shows the exit status and the first error;
- a named tag (DeepSeek's manual run) is honoured;
- the issue is updated rather than duplicated, a block already reported is left alone, and a resolved one is
  closed;
- the keep-alive commit.

Lint: `shellcheck -x -s bash sync.sh pack-shrinkwrap.sh test/sync-test.sh test/stubs/* forks/*.env` and
`actionlint`.

## Limits

- **It never resolves a conflict.** Measured over May–November 2026 with the changelog kept apart, conflicts hit
  about 18% of Claude releases (one block of `acp-agent.ts`), 6% of Gemini's and 4% of Kimi's.
- **A green check is only the checks.** A break the patch's tests don't cover gets through, so drgnx moves its pin
  only after its own adapter rows pass on the new release.
- **The pack commands for Gemini and Kimi run first on the runner.** claude-agent-acp's packing and
  `pack-shrinkwrap.sh` were checked on a real build. A failing pack is a red outcome, so nothing is released.
- **A monorepo package's shrinkwrap is resolved at build time,** not taken from the lockfile the checks used.
- The tag a GitHub release creates is lightweight.
- A run that fails for another reason (a script error, an upstream tag moved mid-run) pushes nothing. GitHub emails
  the failed run, and the next run retries.
