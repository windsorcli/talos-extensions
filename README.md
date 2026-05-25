# Windsor Talos Extensions

Build, version, and publish [Talos Linux system extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/) for Windsor clusters.

Extensions are OCI images (a `manifest.yaml` plus a `rootfs` tree) published to `ghcr.io/windsorcli`. A release tag bundles digests in the catalog image `ghcr.io/windsorcli/extensions:<tag>`.

Open source under [MPL 2.0](LICENSE). Used with [Windsor Core](https://github.com/windsorcli/core) and the [Windsor CLI](https://github.com/windsorcli/cli).

## Using extensions

### With Talos Image Factory (Windsor Terraform)

[Windsor Core](https://github.com/windsorcli/core) can bake extensions into installer images via Image Factory schematics. Official Sidero extensions use names like `siderolabs/iscsi-tools`.

Windsor extensions are consumed by **pinned OCI reference** in machine config or schematics until registered with Image Factory. Resolve a digest from the catalog image:

```bash
./scripts/resolve-extension.sh windsor-hello v0.1.0
```

Always pin the full `@sha256:…` digest in production.

### Verifying images

Every published image is signed with [cosign](https://github.com/sigstore/cosign) using GitHub's OIDC identity — no Windsor-managed keys. Each image also carries SLSA build provenance and an SPDX SBOM as OCI attestations. Verify before you trust:

```bash
cosign verify ghcr.io/windsorcli/windsor-hello@sha256:<digest> \
  --certificate-identity-regexp 'https://github.com/windsorcli/talos-extensions/\.github/workflows/ci\.yaml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Inspect SBOM / provenance attestations
cosign download attestation ghcr.io/windsorcli/windsor-hello@sha256:<digest>
```

### With Windsor contexts

In a Windsor context, set Talos extensions on the cluster facet (see Core `cluster/talos/extensions`). Today that path uses Image Factory `officialExtensions` names (`siderolabs/…`). For Windsor-built extensions, reference the resolved image in your Talos machine config or extend the schematic to use custom extension overlays.

## Extension catalog

| Name | Tier | Image | Description |
| --- | --- | --- | --- |
| [windsor-hello](contrib/windsor-hello/) | contrib | `ghcr.io/windsorcli/windsor-hello` | CI smoke-test extension |

## Developing

### Prerequisites

- git, make, docker 19.03+ with [buildx](https://docs.docker.com/build/buildx/)
- [crane](https://github.com/google/go-containerregistry/tree/main/cmd/crane) and [yq](https://github.com/mikefarah/yq) for catalog tooling
- [yamllint](https://yamllint.readthedocs.io), [shellcheck](https://www.shellcheck.net), and [conftest](https://www.conftest.dev) for local lint (CI runs them anyway)
- [cosign](https://github.com/sigstore/cosign) to verify published images

```bash
docker buildx create --name local --use
```

### Build locally

```bash
# Single extension (amd64)
make windsor-hello PLATFORM=linux/amd64

# Inspect rootfs locally
make local-windsor-hello PLATFORM=linux/amd64 DEST=_out/windsor-hello

# Full catalog image (after all targets built)
make extensions PLATFORM=linux/amd64
```

### Lint and validate

```bash
yamllint .
shellcheck scripts/*.sh hack/*.sh
conftest test --policy policy contrib/*/manifest.yaml contrib/*/pkg.yaml
# Cross-file checks (name consistency between manifest.yaml and pkg.yaml):
for dir in contrib/*; do
  conftest test --policy policy --combine "$dir/manifest.yaml" "$dir/pkg.yaml"
done
```

Policies live in [`policy/`](policy/) as Rego ([Open Policy Agent](https://www.openpolicyagent.org)).

### Add an extension

1. Copy [`extensions/_template`](extensions/_template) to `contrib/<name>/` or `services/<name>/`.
2. Implement `manifest.yaml` and `pkg.yaml`.
3. Add `<name>` to `spec.targets` in [`.kres.yaml`](.kres.yaml), then run `make rekres`.
4. Open a PR — CI builds on `linux/amd64`.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Releases

- **main** — images pushed to `ghcr.io/windsorcli/*` on every merge.
- **tags** `v*` — draft GitHub release with generated notes; catalog image tagged to match.

[Release Drafter](.github/release-drafter.yml) manages version bumps from PR labels.

## Related projects

- [siderolabs/extensions](https://github.com/siderolabs/extensions) — upstream Talos extensions
- [windsorcli/core](https://github.com/windsorcli/core) — platform blueprint with Talos extension upgrades
