#!/usr/bin/env bash
# Assemble manifest.yaml + rootfs/ and publish an OCI extension image (crane or docker).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-v0.1.0}"
IMAGE="${IMAGE:-ghcr.io/windsorcli/hyper-v-linux-guest:${VERSION}}"
LINUX_TOOLS_TAG="${LINUX_TOOLS_TAG:-v6.12.28}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/rootfs/usr/local/lib/containers/hyperv-kvp" \
  "$work/rootfs/usr/local/lib/containers/hyperv-vss" \
  "$work/rootfs/usr/local/etc/containers"

sed "s/{{ .VERSION }}/${VERSION#v}/g; s/{{ .TIER }}/contrib/g" \
  "$ROOT/manifest.yaml.tmpl" >"$work/manifest.yaml"

docker build -f "$ROOT/Dockerfile" --build-arg "LINUX_TOOLS_TAG=$LINUX_TOOLS_TAG" \
  --target artifacts -t hyper-v-linux-guest-build:local "$ROOT"
cid="$(docker create hyper-v-linux-guest-build:local)"
docker cp "$cid:/hv_kvp_daemon" "$work/rootfs/usr/local/lib/containers/hyperv-kvp/"
docker cp "$cid:/hv_vss_daemon" "$work/rootfs/usr/local/lib/containers/hyperv-vss/"
docker rm "$cid" >/dev/null

cp "$ROOT/src/run-hyperv-kvp.sh" "$work/rootfs/usr/local/lib/containers/hyperv-kvp/"
chmod +x "$work/rootfs/usr/local/lib/containers/hyperv-kvp/"{run-hyperv-kvp.sh,hv_kvp_daemon}
chmod +x "$work/rootfs/usr/local/lib/containers/hyperv-vss/hv_vss_daemon"
cp "$ROOT/hyperv-kvp.yaml" "$ROOT/hyperv-vss.yaml" "$work/rootfs/usr/local/etc/containers/"

if command -v crane >/dev/null 2>&1; then
  crane append -f "$work/manifest.yaml" -f "$work/rootfs" -t "$IMAGE"
  echo "Published $IMAGE"
elif command -v docker >/dev/null 2>&1; then
  tar -C "$work" -cf - manifest.yaml rootfs | docker import - "$IMAGE"
  echo "Imported $IMAGE (push with: docker push ...)"
else
  echo "Built layout at $work (install crane or docker to publish)"
  cp -a "$work" "$ROOT/.build-out"
  trap - EXIT
  rm -rf "$work"
  echo "Copied to $ROOT/.build-out"
fi
