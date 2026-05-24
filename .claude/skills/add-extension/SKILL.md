---
name: add-extension
description: Scaffold a new Talos system extension in this repo from `extensions/_template/`. Walks through naming, copying the template into `contrib/<name>/`, filling in `manifest.yaml` + `pkg.yaml`, wiring the target into `.kres.yaml`, regenerating the Makefile with `make rekres`, updating the README catalog, and verifying the build. Use when the user says "add an extension", "scaffold a new extension", "create a new Talos extension", or names a tool they want packaged (e.g. "add fio").
disable-model-invocation: true
---

# Add Extension

Scaffold a new Talos system extension from `extensions/_template/`,
wire it into the build, and verify it. Authoring is mostly editing two
small YAML files (`manifest.yaml` + `pkg.yaml`) and adding a target to
`.kres.yaml`. The build system, CI, and release flow pick it up
automatically once the target is wired.

This skill is for the **scaffolding** workflow. For nontrivial build
steps (kernel modules, fetching upstream binaries, linking against
Talos `PKGS` / `TOOLS`), point the author at the Sidero
[extensions guide](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
and the patterns in
[siderolabs/extensions](https://github.com/siderolabs/extensions) —
this skill doesn't try to author novel build recipes.

## Apply when
- The user says "add an extension", "scaffold an extension", "new
  Talos extension", or names a specific tool to package.
- The repo is `windsorcli/talos-extensions` (or a fork): has
  `extensions/_template/`, `.kres.yaml` with `spec.targets`, and a
  generated `Makefile`.

## Do not apply when
- The user wants to **modify** an existing extension — edit
  `contrib/<name>/{manifest,pkg}.yaml` directly; no scaffolding needed.
- The user wants to **remove** an extension — different workflow
  (delete the directory, remove from `.kres.yaml` targets, `make
  rekres`, update README catalog).
- The user wants help **publishing** or **resolving digests** — see
  `scripts/resolve-extension.sh` and the release section of the README.

## Inputs to gather

Up front, with one question each, get:

1. **Extension name.** Lowercase, hyphen-separated, no
   `windsor-`/`talos-` prefix unless it's genuinely the brand
   (`windsor-hello` is a smoke-test, not a pattern). Becomes the
   directory name, `metadata.name`, `pkg.yaml` `name:`, image name,
   and target in `.kres.yaml`.
2. **Category.** Today only `contrib/` exists. The README and
   `_template` both mention a hypothetical `services/`, but the layout
   is `contrib/<name>/` until a maintainer creates a new tier. Default
   to `contrib/`.
3. **What it does.** One or two sentences for `metadata.description`.
4. **Talos compatibility.** Minimum version, e.g. `">= v1.10.0"`. If
   unsure, copy from a recent extension or default to the template's
   `">= v1.10.0"`.
5. **Author / maintainer.** Goes in `metadata.author`. Default to
   `Windsor CLI` for repo-owned extensions; use a person/org name for
   contributed ones.

If the author can't answer build-step questions yet, scaffold the
template as-is (empty `finalize`-only `pkg.yaml`) and leave the heavy
lifting for a follow-up commit.

## Step-by-step

1. **Verify the name is free.**
   ```bash
   test -e contrib/<name> && echo "DIR EXISTS" || echo "ok"
   grep -n '<name>' .kres.yaml || echo "not in kres targets"
   ```
   If either trips, stop and ask for a new name.

2. **Copy the template.**
   ```bash
   cp -R extensions/_template contrib/<name>
   ```

3. **Fill in `contrib/<name>/manifest.yaml`** — replace every field
   sourced from the inputs:
   - `metadata.name` → `<name>`
   - `metadata.version` → starting version, typically `0.0.1` (note:
     this is the *extension manifest* version, distinct from the
     repo's release tag).
   - `metadata.author` → author/maintainer
   - `metadata.description` → 1-2 sentence prose; preserve the `|`
     block-literal style from the template.
   - `compatibility.talos.version` → e.g. `">= v1.10.0"`

4. **Fill in `contrib/<name>/pkg.yaml`** — start from the template:
   - `name:` → `<name>` (must match `metadata.name`)
   - `variant: scratch` is the default for non-compiling extensions
     (smoke tests, manifest-only, prebuilt-binary copies).
   - The default `finalize` includes `/rootfs` and `/pkg/manifest.yaml`.
     If the extension has no `/rootfs` payload (e.g.
     `contrib/windsor-hello`), **remove the `/rootfs` finalize entry**
     so `bldr` doesn't fail on a missing path.
   - For extensions that build kernel modules or link against Talos
     packages: add `dependencies:` / `steps:` blocks per the Sidero
     guide. Pin against the `PKGS` / `TOOLS` version that matches the
     target Talos line — see the `PKGS` / `TOOLS` defaults in the
     generated `Makefile` (`v1.12.5` at time of writing) and override
     via `make` env vars if needed.

5. **Update `contrib/<name>/README.md`.** One short paragraph: what
   it does, who/what it's for, and any caveats. Cross-link from the
   top-level catalog table.

6. **Wire the target into `.kres.yaml`.** Add `<name>` to the
   `pkgfile.Build` `spec.targets:` list, alphabetically:
   ```yaml
   spec:
     targets:
       - <name>
       - windsor-hello
   ```
   Stay inside the `kind: pkgfile.Build` document — there are several
   YAML documents in `.kres.yaml`; the right one is at the top.

7. **Regenerate the Makefile.**
   ```bash
   make rekres
   ```
   This invokes the kres image and rewrites `Makefile` from
   `.kres.yaml`. Diff the `Makefile` change before staging — the
   expected delta is a new phony target block for `<name>` and an
   entry in the aggregate target list. **Never hand-edit `Makefile`**;
   it carries an auto-generated banner.

8. **Update the catalog table in `README.md`.** Append a row to the
   "Extension catalog" table:
   ```
   | [<name>](contrib/<name>/) | contrib | `ghcr.io/windsorcli/<name>` | <short description> |
   ```
   Keep the column order and alignment of the existing rows. Tier is
   `contrib` for now (see Step 2).

9. **Run local gates.**
   ```bash
   yamllint .
   shellcheck scripts/*.sh hack/*.sh
   conftest test --policy policy contrib/<name>/manifest.yaml contrib/<name>/pkg.yaml
   conftest test --policy policy --combine contrib/<name>/manifest.yaml contrib/<name>/pkg.yaml
   make <name> PLATFORM=linux/amd64
   ```
   - `yamllint` catches indentation/quoting bugs.
   - `shellcheck` only matters if you touched shell scripts; harmless
     to run otherwise.
   - `conftest` enforces the schema in `policy/extension.rego`:
     metadata fields, semver, kebab-case names, Talos compat
     constraint, manifest.yaml ↔ pkg.yaml name consistency. The
     `--combine` run is the cross-file check; the first run is
     per-file.
   - `make <name>` runs the actual `bldr` build via docker buildx;
     requires a working buildx setup (`docker buildx create --name
     local --use`). If buildx is unavailable, say so and rely on CI.
   - For an extension with real build steps, also try a local rootfs
     inspection: `make local-<name> PLATFORM=linux/amd64 DEST=_out/<name>`.

10. **Stage and STOP.** `git add` the specific paths:
    ```bash
    git add contrib/<name>/ .kres.yaml Makefile README.md
    ```
    Show `git status --short` and `git diff --cached --stat`. Hand
    back to the author: "Scaffolded `<name>`. Ready for your review —
    give me the go-ahead to commit, or call out changes."

11. **On the author's go-ahead**, commit with a Conventional
    Commits-style message and the standard `Co-Authored-By` trailer.
    Sample voice from this repo: `git log main --pretty=format:%s |
    head -5`. Typical title: `feat(<name>): add <name> extension`.

## What NOT to do

- **Don't hand-edit `Makefile`.** It's regenerated from `.kres.yaml`
  by `make rekres`.
- **Don't skip yamllint.** A bad indent in `pkg.yaml` is caught
  locally in 2 seconds and remotely in 2 minutes.
- **Don't pick a tag-line version for `metadata.version`.** That
  field tracks the extension manifest, not the repo release. Start at
  `0.0.1` (or `0.1.0` if the extension is shipping in some form on
  day one) and bump separately from the repo's `vX.Y.Z` tags.
- **Don't auto-commit.** Stage and pause for author review, same as
  `address-pr-feedback`.
- **Don't add a `services/` directory** just because the README
  mentions it. Stick to `contrib/` until a maintainer introduces the
  new tier.
- **Don't pin `PKGS`/`TOOLS` casually.** If you change defaults in
  `.kres.yaml`, you're shifting the Talos line every extension
  builds against. Override per-extension via `make` env vars if a
  single extension needs a different pin.

## Tone

Calm, prose-first, brief. The author is filling in 4-5 YAML fields
and approving a generated `Makefile` diff — most of the value is
catching the easy mistakes (name mismatches between `manifest.yaml`
`metadata.name` and `pkg.yaml` `name`, forgetting the `.kres.yaml`
target, leaving the `/rootfs` finalize for a manifest-only extension).
Lead with those, then get out of the way.
