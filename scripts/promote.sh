#!/usr/bin/env bash
# promote.sh <version>: moves the two floating references of the release line <major>.<minor>
# of <version> to its newest stable patch whose image $IMAGE:<patch> exists, <version> or a
# newer one: first the git tag v<major>.<minor> (to the commit of v<patch>), then the image tag
# $IMAGE:<major>.<minor> (a copy of $IMAGE:<patch>). A reference already there stays untouched.
# The patches are the git tags v<major>.<minor>.<patch> of origin read at promotion time, so a
# release also completes a promotion of a newer patch that was cancelled or failed; newer
# patches whose image cannot be read yet are skipped. A refused git push leaves both references
# where they were. It fails, moving nothing, when it reaches the image of <version>, or of the
# patch the git tag points at, and cannot read it: a registry error never leaves the line
# silently behind its release or moves it back.
#
#   promote.sh <version>   in a clone of rfabric/cli that may push tags, logged in to the
#                          registry of IMAGE; .github/workflows/image.yml runs it
#   source promote.sh      defines the functions below (tests/unit.sh)
set -uo pipefail

# stable_patches <line>: the stable tags v<line>.<patch> among the tag names on stdin
# (refs/tags/ prefixes allowed), newest first.
stable_patches() {
  local line=${1//./\\.}
  sed -E 's#^refs/tags/##' | { grep -E "^v$line\.[0-9]+$" || true; } | sort -rV
}

# image_digest <reference>: the digest of the image (its index for a multi-platform image);
# fails when the registry has no such image or cannot be read.
image_digest() {
  docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$1"
}

# promote <version>: see the header.
promote() {
  local version=$1 line floating tag patch="" digest
  if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "promote.sh: '$version' is not <major>.<minor>.<patch>" >&2
    return 2
  fi
  [[ -n ${IMAGE:-} ]] || { echo "promote.sh: IMAGE is not set" >&2; return 2; }
  line=${version%.*}
  # v<line>* also matches the floating tag v<line> itself, other lines and prereleases;
  # stable_patches keeps the line's stable patches.
  git fetch --quiet --force origin "+refs/tags/v$line*:refs/tags/v$line*" || return 1
  floating=$(git rev-parse --verify -q "refs/tags/v$line^{commit}")
  for tag in $(git tag --list "v$line.*" | stable_patches "$line"); do
    if digest=$(image_digest "$IMAGE:${tag#v}"); then
      patch=${tag#v}
      break
    fi
    if [[ $tag == "v$version" ]]; then
      echo "promote.sh: the image $IMAGE:$version of this release cannot be read; nothing moved" >&2
      return 1
    fi
    if [[ $(git rev-parse "$tag^{commit}") == "$floating" ]]; then
      echo "promote.sh: v$line points at $tag, whose image $IMAGE:${tag#v} cannot be read; nothing moved" >&2
      return 1
    fi
  done
  if [[ -z $patch ]]; then
    echo "promote.sh: origin has no tag v$version; nothing moved" >&2
    return 1
  fi
  if [[ $(git rev-parse "v$patch^{commit}") != "$floating" ]]; then
    git push --quiet --force origin "v$patch^{commit}:refs/tags/v$line" || return 1
  fi
  if [[ $(image_digest "$IMAGE:$line" 2> /dev/null) != "$digest" ]]; then
    docker buildx imagetools create --tag "$IMAGE:$line" "$IMAGE:$patch" || return 1
  fi
  echo "v$line and $IMAGE:$line point at $patch"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# -eq 1 ]] || { echo "usage: promote.sh <version>" >&2; exit 2; }
  promote "$1"
  exit $?
fi
