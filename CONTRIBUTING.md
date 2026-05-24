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

## Releases

Maintainers publish releases from drafted Release Drafter notes. Tag format: `vX.Y.Z`, aligned with the Talos version line the release targets when possible.

Every released image — per-extension and the catalog — is signed with cosign keyless. Consumers can verify with the command in [README.md](README.md#verifying-images).
