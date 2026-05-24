package main

import rego.v1

# Policies for Talos system-extension manifest.yaml and pkg.yaml files.
#
# Run locally:
#   conftest test --policy policy contrib/*/manifest.yaml contrib/*/pkg.yaml
#
# Cross-file checks (manifest.yaml + pkg.yaml in the same extension dir) run
# under `--combine`:
#   conftest test --policy policy --combine contrib/<name>/manifest.yaml contrib/<name>/pkg.yaml
#
# The CI workflow runs both forms; see .github/workflows/ci.yaml.

# ---------------------------------------------------------------------------
# Per-file rules (default mode).
# ---------------------------------------------------------------------------

# manifest.yaml rules ------------------------------------------------------

is_manifest if {
	input.version == "v1alpha1"
	input.metadata
}

deny contains msg if {
	is_manifest
	not input.metadata.name
	msg := "manifest.yaml: metadata.name is required"
}

deny contains msg if {
	is_manifest
	input.metadata.name
	not regex.match(`^[a-z][a-z0-9-]*[a-z0-9]$`, input.metadata.name)
	msg := sprintf("manifest.yaml: metadata.name %q must be lowercase kebab-case", [input.metadata.name])
}

deny contains msg if {
	is_manifest
	not input.metadata.version
	msg := "manifest.yaml: metadata.version is required"
}

deny contains msg if {
	is_manifest
	input.metadata.version
	not regex.match(`^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$`, input.metadata.version)
	msg := sprintf("manifest.yaml: metadata.version %q must be semver (X.Y.Z[-pre])", [input.metadata.version])
}

deny contains msg if {
	is_manifest
	not input.metadata.author
	msg := "manifest.yaml: metadata.author is required"
}

deny contains msg if {
	is_manifest
	not input.metadata.description
	msg := "manifest.yaml: metadata.description is required"
}

deny contains msg if {
	is_manifest
	input.metadata.description
	trimmed := trim_space(input.metadata.description)
	count(trimmed) < 10
	msg := sprintf("manifest.yaml: metadata.description %q is too short (need at least 10 chars of prose)", [trimmed])
}

deny contains msg if {
	is_manifest
	not input.metadata.compatibility.talos.version
	msg := "manifest.yaml: compatibility.talos.version is required (e.g. \">= v1.10.0\")"
}

deny contains msg if {
	is_manifest
	v := input.metadata.compatibility.talos.version
	not regex.match(`^(>=|>|=|~|\^)?\s*v?[0-9]+\.[0-9]+\.[0-9]+`, v)
	msg := sprintf("manifest.yaml: compatibility.talos.version %q does not look like a valid constraint", [v])
}

# pkg.yaml rules -----------------------------------------------------------

is_pkg if {
	input.name
	input.variant
	not input.metadata  # disambiguate from manifest.yaml which also has a top-level `name` in some shapes
}

deny contains msg if {
	is_pkg
	not regex.match(`^[a-z][a-z0-9-]*[a-z0-9]$`, input.name)
	msg := sprintf("pkg.yaml: name %q must be lowercase kebab-case", [input.name])
}

deny contains msg if {
	is_pkg
	input.variant != "scratch"
	input.variant != "alpine"
	msg := sprintf("pkg.yaml: variant %q is unusual (expected \"scratch\" or \"alpine\"); double-check intent", [input.variant])
}

deny contains msg if {
	is_pkg
	not has_manifest_finalize
	msg := "pkg.yaml: finalize must copy /pkg/manifest.yaml to / so the extension exposes its manifest"
}

has_manifest_finalize if {
	some entry in input.finalize
	entry.from == "/pkg/manifest.yaml"
	entry.to == "/"
}

# ---------------------------------------------------------------------------
# Cross-file rules (run with `conftest test --combine`).
# ---------------------------------------------------------------------------

# Under --combine, `input` is a list of objects with .path and .contents.

manifest_in_combined := m if {
	some entry in input
	endswith(entry.path, "/manifest.yaml")
	m := entry.contents
}

pkg_in_combined := p if {
	some entry in input
	endswith(entry.path, "/pkg.yaml")
	p := entry.contents
}

deny contains msg if {
	manifest_in_combined
	pkg_in_combined
	manifest_in_combined.metadata.name != pkg_in_combined.name
	msg := sprintf(
		"manifest.yaml metadata.name (%q) must match pkg.yaml name (%q)",
		[manifest_in_combined.metadata.name, pkg_in_combined.name],
	)
}
