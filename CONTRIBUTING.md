# Contributing

## Adding an extension

1. Copy `extensions/_template/` into a category directory, for example `contrib/my-tool/`.
2. Set `metadata.name` in `manifest.yaml` and implement `pkg.yaml` using [Sidero’s extension guide](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/) and examples in [siderolabs/extensions](https://github.com/siderolabs/extensions).
3. Add the bldr target name to `.kres.yaml` → `spec.targets`.
4. Run `make rekres` and commit the updated `Makefile` if it changes.
5. Document the extension in `README.md` (catalog table) and add a short `README.md` in the extension directory.

## Pull requests

- Keep Talos version compatibility accurate in `manifest.yaml`.
- Pin `PKGS` / `TOOLS` in the Makefile when your extension builds kernel modules or links against Talos packages.
- CI builds all targets on amd64 for PRs; main publishes amd64 and arm64.

## CI gates

PRs run two jobs:

- **lint** — `yamllint`, `shellcheck` (on `scripts/*.sh` and `hack/*.sh`), and `conftest` against the policies in [`policy/`](policy/). Schema-validates every `manifest.yaml` and `pkg.yaml` under `contrib/` and `extensions/_template/`, plus a cross-file check that `metadata.name` matches `pkg.yaml` `name`. Run locally with the commands in [README.md](README.md#lint-and-validate) before you push.
- **build** — `docker buildx` per extension target. On non-PR events also pushes to ghcr.io, signs every image with cosign keyless (GitHub OIDC), and attaches SLSA build provenance and an SPDX SBOM as OCI attestations.

## Testing extensions

### Locally, end-to-end (no remote pushes)

```bash
./hack/test-extension-local.sh <extension-name> [talos-version]
```

Runs the full pipeline on your workstation: spins up a `localhost:5000` registry, builds the extension, assembles a custom Talos installer with `imager`, boots a `talosctl cluster create --provisioner docker` cluster with that installer, and prints `talosctl get extensions` + service logs. Tears down on exit. Requires `docker` and `talosctl`; nothing pushes to ghcr.io.

Hardware-coupled extensions (anything depending on vmbus, specific PCI devices, etc.) will install cleanly in the local cluster but their daemons won't have the hardware to talk to — use the local script to validate packaging, then test on real hardware for end-to-end function.

### What CI runs

Today's CI gates are schema (conftest), lint (yamllint, shellcheck), build (bldr/buildx), sign (cosign), and verify-self (the documented `cosign verify` command runs against the just-signed images). That's enough for a manifest-only or simple-rootfs extension.

For extensions that ship binaries, kernel modules, or anything with runtime behavior, the first such extension should also land:

- A **bldr `test-extension` stage** in `Pkgfile` — `RUN` assertions during build that fail the build if the extension is broken (e.g. `RUN /rootfs/usr/local/bin/foo --version`). See [siderolabs/extensions `hack/test/pkg.yaml`](https://github.com/siderolabs/extensions/blob/main/hack/test/pkg.yaml) for the pattern.
- A **container-structure-test** YAML per extension under a new `tests/` dir, asserting files exist at expected paths with correct modes.

These weren't scaffolded up-front because `windsor-hello` is a scratch manifest-only smoke test and trivial assertions against it would rot before the first real extension lands. The first non-trivial extension's PR should bring the harness with it.

## Releases

Maintainers publish releases from drafted Release Drafter notes. Tag format: `vX.Y.Z`, aligned with the Talos version line the release targets when possible.

Every released image — per-extension and the catalog — is signed with cosign keyless. Consumers can verify with the command in [README.md](README.md#verifying-images).
