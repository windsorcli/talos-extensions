#!/usr/bin/env bash
# Test an extension end-to-end on a local Talos cluster — no remote pushes.
#
# Pipeline:
#   1. Ensure a local OCI registry is running on localhost:5000
#   2. Build the extension via `make` and push to localhost:5000
#   3. Build a Talos installer with imager that embeds the extension
#   4. Load the installer tar into the local docker daemon
#   5. `talosctl cluster create --provisioner "$PROVISIONER"` using the loaded installer
#   6. Print `get extensions` + `services` for verification
#   7. Always tear the cluster down on exit
#
# Usage:
#   ./hack/test-extension-local.sh <extension-name> [talos-version]
#
# Examples:
#   ./hack/test-extension-local.sh windsor-hello
#   ./hack/test-extension-local.sh hyperv-guest v1.12.5
#
# What this validates vs doesn't:
#   ✓ Extension builds via bldr (catches mergeop, missing /rootfs, etc.)
#   ✓ Extension pushes to a registry
#   ✓ Imager accepts the extension and assembles it into an installer
#   ✓ Installer is structurally valid (loads into docker)
#   ✓ Talos cluster boots from a configuration
#
# WITH PROVISIONER=docker (the default — fast, 60-90s):
#   ✗ Extension is NOT actually loaded into Talos. Docker provisioner boots
#     from a base Talos container image; --install-image is only used for
#     upgrades, not initial boot. `talosctl get extensions` will be empty.
#     Use this for build-pipeline smoke testing only.
#
# WITH PROVISIONER=qemu (heavier, ~5-10 min, needs qemu installed):
#   ✓ Real install path runs — extension lands in initramfs and the services
#     start. `talosctl get extensions` shows the extension; service logs
#     reflect actual runtime behavior.
#
# Hardware-coupled extensions (vmbus for hyperv-guest, specific PCI
# pass-through, etc.) install cleanly in qemu but their daemons may not
# function — verify on real hardware for full validation.

set -euo pipefail

EXTENSION="${1:?usage: $0 <extension-name> [talos-version]}"
TALOS_VERSION="${2:-v1.12.5}"

REGISTRY_NAME="windsor-ext-test-registry"
# 5000 is taken by macOS ControlCenter (AirPlay Receiver) by default; 15000
# is high enough to dodge most defaults. Override with REGISTRY_PORT=... env.
REGISTRY_PORT="${REGISTRY_PORT:-15000}"
CLUSTER_NAME="ext-test"
# docker = fast smoke (~60s), but extension is NOT actually loaded.
# qemu  = slow but real (~5-10 min), extension actually runs.
PROVISIONER="${PROVISIONER:-docker}"
# bldr's multi-source finalize uses BuildKit's `mergeop`, which the default
# `desktop-linux` builder rejects unless Docker Desktop's containerd image
# store is enabled. The `docker-container` driver supports mergeop natively.
BUILDX_BUILDER_NAME="windsor-ext-builder"
CREATED_CLUSTER=false
OUT_DIR="$(pwd)/_out"
EXTENSION_DIR="contrib/${EXTENSION}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

command -v docker   >/dev/null 2>&1 || fail "docker is required"
command -v talosctl >/dev/null 2>&1 || fail "talosctl is required (https://www.talos.dev/latest/talos-guides/install/talosctl/)"

# talosctl's qemu provisioner is Linux-only — it needs KVM, TUN/TAP, and
# Linux bridge networking. macOS (HVF/Virtualization.framework) is not
# supported. Use PROVISIONER=docker on macOS, or run on a Linux box.
if [ "$PROVISIONER" = "qemu" ] && [ "$(uname -s)" != "Linux" ]; then
  fail "PROVISIONER=qemu requires Linux (KVM-based). Use docker on macOS, or run this script on a Linux host / CI."
fi

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

log "Testing extension '$EXTENSION' v$EXT_VERSION against Talos $TALOS_VERSION"

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

cleanup() {
  local rc=$?
  set +e
  # Only destroy if WE created the cluster this run. `talosctl cluster show`
  # exits 0 even for nonexistent clusters, so it's not a reliable existence
  # probe — use an explicit flag set after `cluster create` succeeds.
  if [ "$CREATED_CLUSTER" = true ]; then
    log "Tearing down cluster '$CLUSTER_NAME'"
    talosctl cluster destroy --name "$CLUSTER_NAME" --provisioner "$PROVISIONER"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

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
# 3. Imager: build a Talos installer that embeds the extension
# ---------------------------------------------------------------------------

mkdir -p "$OUT_DIR"
log "Running imager to assemble custom installer (Talos $TALOS_VERSION)"
# --network host so imager can reach localhost:5000 from inside the container.
docker run --rm -t \
  --network host \
  -v "$OUT_DIR:/out" \
  "ghcr.io/siderolabs/imager:$TALOS_VERSION" installer \
  --system-extension-image "$EXT_IMAGE" \
  --arch amd64

# Imager output filename varies by version (installer-amd64.tar,
# metal-amd64.tar, etc.). Pick the newest *.tar in _out/.
INSTALLER_TAR="$(find "$OUT_DIR" -maxdepth 1 -name '*.tar' -type f -print0 \
  | xargs -0 ls -t 2>/dev/null | head -1)"
[ -n "$INSTALLER_TAR" ] && [ -f "$INSTALLER_TAR" ] \
  || fail "imager did not produce an installer tar in $OUT_DIR"

# ---------------------------------------------------------------------------
# 4. Load (docker) / push (qemu) the installer so the cluster can use it
# ---------------------------------------------------------------------------

# talosctl defaults to 10.5.0.0/24 which collides with core's `windsor-local`
# and most lab networks. Pick a high-range CIDR; override with CLUSTER_CIDR=...
CLUSTER_CIDR="${CLUSTER_CIDR:-10.224.0.0/24}"

log "Loading installer image into local docker daemon"
INSTALLER_IMAGE_LOCAL="$(docker load -i "$INSTALLER_TAR" \
  | awk -F': ' '/Loaded image/ {print $2; exit}')"
[ -n "$INSTALLER_IMAGE_LOCAL" ] || fail "could not parse loaded image name from docker load output"
log "Loaded as: $INSTALLER_IMAGE_LOCAL"

CLUSTER_FLAGS=(
  --name "$CLUSTER_NAME"
  --provisioner "$PROVISIONER"
  --cidr "$CLUSTER_CIDR"
  --wait
)

if [ "$PROVISIONER" = "qemu" ]; then
  # QEMU VMs can't see the host's docker image store — they pull from a
  # registry over the cluster network. Push the installer to our local
  # registry; the VMs reach it at the gateway IP (first usable in CIDR).
  GATEWAY_IP="$(awk -F'[./]' '{printf "%s.%s.%s.%d", $1,$2,$3,$4+1}' <<<"$CLUSTER_CIDR")"
  REG_FROM_VM="${GATEWAY_IP}:${REGISTRY_PORT}"
  INSTALLER_TAG="installer-${EXTENSION}-${EXT_VERSION}"

  log "Pushing installer to local registry for QEMU VMs (gateway $REG_FROM_VM)"
  docker tag "$INSTALLER_IMAGE_LOCAL" "${LOCAL_REGISTRY}/test/${INSTALLER_TAG}:latest"
  docker push "${LOCAL_REGISTRY}/test/${INSTALLER_TAG}:latest" >/dev/null

  # Same blob, addressed under the VM-visible registry hostname.
  INSTALLER_FOR_VMS="${REG_FROM_VM}/test/${INSTALLER_TAG}:latest"
  CLUSTER_FLAGS+=(
    --install-image "$INSTALLER_FOR_VMS"
    --registry-insecure-skip-verify "$REG_FROM_VM"
  )
else
  # Docker provisioner: VMs are containers on the host docker daemon,
  # so the locally-loaded image is reachable by name.
  CLUSTER_FLAGS+=(--install-image "$INSTALLER_IMAGE_LOCAL")
fi

# ---------------------------------------------------------------------------
# 5. Spin up local Talos cluster
# ---------------------------------------------------------------------------

log "Creating local Talos cluster '$CLUSTER_NAME' (provisioner: $PROVISIONER)"
talosctl cluster create "${CLUSTER_FLAGS[@]}"
CREATED_CLUSTER=true

# ---------------------------------------------------------------------------
# 6. Verification
# ---------------------------------------------------------------------------

log "Cluster ready — querying extension state"

# Extract the controlplane node IP from cluster show so subsequent commands
# don't require --nodes flag noise.
CP_IP="$(talosctl cluster show --provisioner "$PROVISIONER" --name "$CLUSTER_NAME" 2>/dev/null \
  | awk '/controlplane/ {print $3; exit}')"
[ -n "$CP_IP" ] || fail "could not resolve controlplane IP from talosctl cluster show"
log "Controlplane: $CP_IP"
talosctl config nodes "$CP_IP" >/dev/null

echo
echo "--- talosctl get extensions ---"
talosctl get extensions || warn "no extensions reported (extension may not have loaded)"
echo
echo "--- talosctl services (filtered to ext-*) ---"
talosctl services 2>/dev/null | awk 'NR==1 || /ext-/' || true
echo
echo "--- per-extension service logs (last 20 lines each) ---"
for svc in $(talosctl services 2>/dev/null | awk '/ext-/ {print $2}'); do
  echo "## $svc"
  talosctl logs "$svc" 2>/dev/null | tail -20 || warn "$svc logs unavailable"
  echo
done

log "Done. Cluster will be destroyed on exit. Press Ctrl+C now to inspect interactively."
sleep 5
