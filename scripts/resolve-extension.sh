#!/usr/bin/env bash
# Resolve a pinned extension image reference from the Windsor extensions catalog.
set -euo pipefail

EXTENSION="${1:?extension name required}"
TAG="${2:-$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || echo main)}"
CATALOG="ghcr.io/windsorcli/extensions:${TAG}"

if ! command -v crane >/dev/null 2>&1; then
  echo "crane is required: go install github.com/google/go-containerregistry/cmd/crane@latest" >&2
  exit 1
fi

crane export "${CATALOG}" 2>/dev/null | tar x -O image-digests | grep -m1 "${EXTENSION}" || {
  echo "extension '${EXTENSION}' not found in ${CATALOG}" >&2
  exit 1
}
