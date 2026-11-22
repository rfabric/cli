#!/usr/bin/env bash
# set-version.sh <version>: pins the wrappers to rfabric <version> (no leading v): writes
# VERSION and stamps the defaults that cannot read VERSION at run time (the GitLab template's
# cli-version input, the pipe image in pipe.yml). cli-src's release workflow runs it before
# each stable release tag.
set -euo pipefail

version=${1:-}
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: set-version.sh <major>.<minor>.<patch>" >&2
  exit 2
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# stamp <file> <sed expression> <line the file must then contain>
stamp() {
  sed -E -i.bak "$2" "$1"
  rm "$1.bak"
  if ! grep -qxF -- "$3" "$1"; then
    echo "set-version.sh: could not stamp $1" >&2
    exit 1
  fi
}

printf '%s\n' "$version" > "$root/VERSION"
stamp "$root/templates/sim-run.yml" \
  "/^    cli-version:/,/^      default:/ s/^(      default: ).*/\\1\"$version\"/" \
  "      default: \"$version\""
stamp "$root/pipe.yml" \
  "s#^(image: ghcr\\.io/rfabric/cli:).*#\\1$version#" \
  "image: ghcr.io/rfabric/cli:$version"
