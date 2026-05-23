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

## Releases

Maintainers publish releases from drafted Release Drafter notes. Tag format: `vX.Y.Z`, aligned with the Talos version line the release targets when possible.
