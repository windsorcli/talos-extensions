#!/usr/bin/env bash

set -e

RELEASE_TOOL_IMAGE="ghcr.io/siderolabs/release-tool:latest"

function release-tool {
  docker pull "${RELEASE_TOOL_IMAGE}" >/dev/null
  docker run --rm -w /src -v "${PWD}":/src:ro "${RELEASE_TOOL_IMAGE}" -l -d -n -t "${1}" ./hack/release.toml
}

function changelog {
  if [ "$#" -eq 1 ]; then
    (release-tool "${1}"; echo; cat CHANGELOG.md) > CHANGELOG.md- && mv CHANGELOG.md- CHANGELOG.md
  else
    echo 1>&2 "Usage: $0 changelog [tag]"
    exit 1
  fi
}

function release-notes {
  release-tool "${2}" > "${1}"
}

if declare -f "$1" > /dev/null; then
  cmd="$1"
  shift
  "$cmd" "$@"
else
  cat <<EOF
Usage:
  $0 changelog [tag]
  $0 release-notes <file> <tag>
EOF
fi
