# Extension template

Copy this directory to a category folder (for example `contrib/my-extension/` or `services/my-extension/`), then:

1. Rename files and update `metadata.name` in `manifest.yaml`.
2. Implement `pkg.yaml` build steps (see [Talos system extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)).
3. Add the target name to `.kres.yaml` under `spec.targets`, then run `make rekres`.
4. Open a PR; CI builds the extension. Releases publish to `ghcr.io/windsorcli/<name>`.
