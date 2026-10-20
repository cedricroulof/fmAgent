#!/bin/zsh
# Builds the release binary into the npm package and checks the package. Publishing stays a manual step:
#   scripts/release-npm.sh 0.2.0 && (cd npm && npm publish)
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/release-npm.sh <version>}

[[ $(uname -m) == arm64 ]] || { echo "build on an Apple Silicon Mac: the package is arm64 only" >&2; exit 1; }
swift build -c release
mkdir -p npm/bin
cp .build/release/fmagent npm/bin/fmagent
cp LICENSE npm/LICENSE
(cd npm && npm version "$version" --no-git-tag-version --allow-same-version >/dev/null && npm pack --dry-run)
echo "\nnpm/ is ready for fmagent@$version. To publish: cd npm && npm publish"
