#!/usr/bin/env bash
# pack-shrinkwrap.sh TARBALL OUTDIR: repack an npm package tarball with an npm-shrinkwrap.json that locks its runtime
# dependencies. For packages built inside a monorepo (npm workspaces, pnpm), whose lockfile can't ship as it is: the
# dependencies are resolved from the registry when the package is built, and locked from then on.
set -euo pipefail
tgz=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(cd "$2" && pwd)
stage=$(mktemp -d)
tar -xzf "$tgz" -C "$stage"
cd "$stage/package"
# devDependencies may name unpublished workspace packages, and a consumer never installs them
npm pkg delete devDependencies
npm install --package-lock-only --ignore-scripts --no-audit --no-fund
mv package-lock.json npm-shrinkwrap.json
# with a "files" list, npm leaves the shrinkwrap out unless it is listed
if [ "$(npm pkg get files)" != "{}" ]; then npm pkg set 'files[]=npm-shrinkwrap.json'; fi
npm pack --ignore-scripts --pack-destination "$out"
