#!/usr/bin/env bash
# Build a Talos `metal-amd64.iso` locally with a custom system extension baked
# in — for booting Hyper-V (or any metal/nocloud) VMs without Image Factory.
#
# Image Factory only serves extensions registered with Sidero. A contrib
# extension like hyperv-guest isn't registered, so the only way to get it onto
# a node at *first boot* is to assemble the ISO ourselves with siderolabs/imager.
#
# Pipeline:
#   1. Ensure a local OCI registry is running on localhost:<REGISTRY_PORT>
#   2. Build the extension via `make` and push it to that registry
#   3. Run `imager iso` to assemble a metal ISO that embeds the extension
#   4. Copy the result to _out/talos-<version>-metal-amd64.iso
#
# Usage:
#   ./hack/build-iso.sh <extension-name> [talos-version]
#
# Examples:
#   ./hack/build-iso.sh hyperv-guest            # defaults to Talos v1.13.3
#   ./hack/build-iso.sh hyperv-guest v1.13.4
#
# Why the nocloud kernel arg (the default):
#   windsorcli/core's Hyper-V platform boots Talos with the Image Factory
#   schematic that adds `talos.platform=nocloud` to the kernel cmdline, so the
#   node reads its config from the CIDATA seed volume core attaches. To stay
#   drop-in compatible with that flow, this ISO bakes the same arg in by
#   default. Override or extend via EXTRA_KERNEL_ARGS (space-separated).
#
# Consuming the result in core (Mac-as-runner over WinRM):
#   Point core at the ISO with `talos.image_local_path` in your context values
#   — the provider streams it to the Windows host instead of downloading from
#   Factory. Relative paths there resolve against core's repo root, so the tidy
#   pattern is to build into core's gitignored isos/ dir and reference it
#   relatively:
#     OUT_DIR="$HOME/Developer/windsorcli/core/isos" ./hack/build-iso.sh hyperv-guest
#     # then in the context values:  talos: { image_local_path: isos/talos-<ver>-metal-amd64.iso }
#   Keep [talos-version] in sync with `talos.talos_version` in core.

set -euo pipefail

EXTENSION="${1:?usage: $0 <extension-name> [talos-version]}"
# Default tracks windsorcli/core's pinned talos.talos_version. Keep in sync.
TALOS_VERSION="${2:-v1.13.3}"

REGISTRY_NAME="windsor-ext-test-registry"
# 5000 is taken by macOS ControlCenter (AirPlay Receiver) by default; 15000
# is high enough to dodge most defaults. Override with REGISTRY_PORT=... env.
REGISTRY_PORT="${REGISTRY_PORT:-15000}"
# Kernel cmdline args baked into the ISO. Defaults to nocloud so the image is
# drop-in compatible with core's CIDATA seed flow. Space-separated; each token
# becomes its own --extra-kernel-arg.
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-talos.platform=nocloud}"
# bldr's multi-source finalize uses BuildKit's `mergeop`, which the default
# `desktop-linux` builder rejects unless Docker Desktop's containerd image
# store is enabled. The `docker-container` driver supports mergeop natively.
BUILDX_BUILDER_NAME="windsor-ext-builder"
# Where the finished ISO lands. Override to build straight into a consuming
# repo's gitignored asset dir, e.g.
#   OUT_DIR="$HOME/Developer/windsorcli/core/isos" ./hack/build-iso.sh hyperv-guest
OUT_DIR="${OUT_DIR:-$(pwd)/_out}"
EXTENSION_DIR="contrib/${EXTENSION}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || fail "docker is required"

# The kres-generated Makefile needs GNU Make 4+ (uses `export define ... endef`)
# and GNU sed (uses `sed -r ...; Q`). macOS ships with GNU Make 3.81 and BSD
# sed, so prefer `gmake` and gnu-sed's gnubin path when present.
MAKE_BIN="make"
if [ "$(uname -s)" = "Darwin" ]; then
  if command -v gmake >/dev/null 2>&1; then
    MAKE_BIN="gmake"
  else
    fail "macOS make is GNU Make 3.81; install GNU Make 4+ via 'brew install make' (provides gmake)"
  fi
  GNU_SED_BIN="/opt/homebrew/opt/gnu-sed/libexec/gnubin"
  if [ ! -x "$GNU_SED_BIN/sed" ]; then
    fail "macOS BSD sed is incompatible with the kres-generated Makefile; install GNU sed via 'brew install gnu-sed'"
  fi
  export PATH="$GNU_SED_BIN:$PATH"
fi

[ -d "$EXTENSION_DIR" ] || fail "extension dir not found: $EXTENSION_DIR"
[ -f "$EXTENSION_DIR/vars.yaml" ] || fail "missing $EXTENSION_DIR/vars.yaml — needed to resolve VERSION"

# Resolve VERSION from vars.yaml (no bldr dependency needed here).
EXT_VERSION="$(awk -F'"' '/^VERSION:/ {print $2; exit}' "$EXTENSION_DIR/vars.yaml")"
[ -n "$EXT_VERSION" ] || fail "could not parse VERSION from $EXTENSION_DIR/vars.yaml"

# core names the parent image talos-<version>-metal-amd64.iso, where <version>
# is the bare talos.talos_version (no leading 'v'). Match that so the file is
# drop-in for hyperv.talos_image_local_path.
TALOS_VERSION_BARE="${TALOS_VERSION#v}"
ISO_OUT="${OUT_DIR}/talos-${TALOS_VERSION_BARE}-metal-amd64.iso"

log "Building ISO for '$EXTENSION' v$EXT_VERSION on Talos $TALOS_VERSION"
log "Kernel args: $EXTRA_KERNEL_ARGS"

# ---------------------------------------------------------------------------
# 1. Local registry
# ---------------------------------------------------------------------------

if docker inspect "$REGISTRY_NAME" >/dev/null 2>&1; then
  # Port mapping is baked at container create time. If a prior run picked a
  # different port (e.g. the script's default changed), force-recreate.
  existing_port="$(docker inspect -f \
    '{{with index .NetworkSettings.Ports "5000/tcp"}}{{(index . 0).HostPort}}{{end}}' \
    "$REGISTRY_NAME" 2>/dev/null || true)"
  if [ "$existing_port" != "$REGISTRY_PORT" ]; then
    log "Recreating registry: existing on :$existing_port, want :$REGISTRY_PORT"
    docker rm -f "$REGISTRY_NAME" >/dev/null
  fi
fi

if ! docker inspect "$REGISTRY_NAME" >/dev/null 2>&1; then
  log "Starting local registry container on :$REGISTRY_PORT"
  docker run -d --restart=always \
    -p "${REGISTRY_PORT}:5000" \
    --name "$REGISTRY_NAME" \
    registry:2 >/dev/null
elif ! docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" | grep -q true; then
  log "Starting existing registry container"
  docker start "$REGISTRY_NAME" >/dev/null
fi

LOCAL_REGISTRY="localhost:${REGISTRY_PORT}"
EXT_IMAGE="${LOCAL_REGISTRY}/test/${EXTENSION}:${EXT_VERSION}"

# ---------------------------------------------------------------------------
# 1b. buildx builder with mergeop support
# ---------------------------------------------------------------------------

if ! docker buildx inspect "$BUILDX_BUILDER_NAME" >/dev/null 2>&1; then
  log "Creating buildx builder '$BUILDX_BUILDER_NAME' (docker-container driver, host network)"
  docker buildx create \
    --name "$BUILDX_BUILDER_NAME" \
    --driver docker-container \
    --driver-opt network=host \
    --bootstrap >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. Build the extension to the local registry
# ---------------------------------------------------------------------------

log "Building $EXTENSION → $EXT_IMAGE (using $MAKE_BIN)"
BUILDX_BUILDER="$BUILDX_BUILDER_NAME" "$MAKE_BIN" "$EXTENSION" \
  REGISTRY="$LOCAL_REGISTRY" \
  USERNAME=test \
  PUSH=true \
  PLATFORM=linux/amd64

# ---------------------------------------------------------------------------
# 3. Imager: assemble a metal ISO that embeds the extension
# ---------------------------------------------------------------------------

mkdir -p "$OUT_DIR"

# Each space-separated token in EXTRA_KERNEL_ARGS becomes its own flag.
IMAGER_ARGS=(iso --arch amd64 --system-extension-image "$EXT_IMAGE")
for karg in $EXTRA_KERNEL_ARGS; do
  IMAGER_ARGS+=(--extra-kernel-arg "$karg")
done

log "Running imager to assemble metal ISO (Talos $TALOS_VERSION)"
# --network host so imager can pull the extension from localhost:<port>.
# go-containerregistry treats localhost registries as plaintext HTTP, so no
# insecure flag is needed for the local registry.
docker run --rm -t \
  --network host \
  -v "$OUT_DIR:/out" \
  "ghcr.io/siderolabs/imager:$TALOS_VERSION" \
  "${IMAGER_ARGS[@]}"

# imager writes /out/metal-amd64.iso. Rename to core's parent-image convention.
RAW_ISO="${OUT_DIR}/metal-amd64.iso"
[ -f "$RAW_ISO" ] || fail "imager did not produce $RAW_ISO"
mv -f "$RAW_ISO" "$ISO_OUT"

# ---------------------------------------------------------------------------
# 4. Done — print next steps
# ---------------------------------------------------------------------------

log "ISO ready: $ISO_OUT"
cat <<EOF

Next steps (windsorcli/core Hyper-V, Mac-as-runner):

  1. In your core context values, point the platform at this ISO. If it lives
     under core's repo root, a relative path is portable (resolves against the
     project root); otherwise use the absolute path below:

       talos:
         image_local_path: "$ISO_OUT"

  2. Ensure core's talos.talos_version matches: $TALOS_VERSION_BARE

  3. windsor up — the hyperv provider streams the ISO to the Windows host
     (C:/hyperv/images/...) instead of downloading from Image Factory.

  4. Once the node is up, confirm the extension loaded:

       talosctl -n <node> get extensions
       talosctl -n <node> services | grep ext-
EOF
