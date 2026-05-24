---
name: review-pr
description: Pre-merge review of an open PR on windsorcli/talos-extensions. Reads the full PR diff, the PR description, and CI status, then runs parallel passes covering extension hygiene, build/release impact, supply-chain integrity, schema/lint sanity, and release-notes alignment. Produces a structured Block / Cautions / Clean verdict so the reviewer knows whether to click Merge. Use when the author says "review the PR", "is this ready to merge?", "merge-gate this PR", or after CI goes green and someone needs final eyes. Pairs with `address-pr-feedback` (the author working through review comments) — `review-pr` is the reviewer's side.
disable-model-invocation: true
---

# Pre-Merge Review

Final review of an open PR before merge. The audience is the reviewer
(or merger), not the author. The output is a verdict — Block,
Cautions, or Clean — backed by concrete findings the reviewer can
cite when commenting or approving.

This is **not** a pre-commit bug hunt over the staged diff (see the
sibling repos' `review-pr` skills for that pattern). It assumes the
author already ran their local gates, CI has run, and what remains is
a holistic check that nothing slipped through.

## Apply when
- The user says "review the PR", "is this ready to merge?", "merge
  gate", or "do a final review".
- There is an open PR on the current branch (`gh pr view` returns a
  PR number) or the user names a PR number.

## Do not apply when
- The branch has no open PR — direct the user to open one first.
- The author wants a pre-commit bug hunt over the staged diff — that's
  a different (currently unwritten) skill in this repo; the closest
  reference is `../cli/.claude/skills/review-pr/SKILL.md`.
- The PR is a draft and CI hasn't run — wait for it.

## Inputs to gather

Run these in parallel at the start and cache the results.

```bash
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
PR_NUM="${1:-$(gh pr view --json number --jq .number)}"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
BASE="$(gh pr view "$PR_NUM" --json baseRefName --jq .baseRefName)"

# Full PR delta (not just the latest commit).
gh pr diff "$PR_NUM"

# PR metadata: title, body, labels, files, author, mergeable state.
gh pr view "$PR_NUM" --json title,body,labels,author,mergeable,mergeStateStatus,reviewDecision,files

# Commit list — for spotting WIP/fixup commits the author forgot to squash.
gh pr view "$PR_NUM" --json commits --jq '.commits[] | {sha: .oid[:7], msg: .messageHeadline, signed: .signatures[0].isValid}'

# CI status — the gate. A red check is almost always a block.
gh pr checks "$PR_NUM"

# Top-level + inline review comments — has someone else already flagged something?
gh api "repos/$REPO/pulls/$PR_NUM/comments" --jq '.[] | {file: .path, line: (.line // .original_line), body: .body, author: .user.login}'
gh api "repos/$REPO/issues/$PR_NUM/comments" --jq '.[] | {body: .body, author: .user.login}'
```

If `gh` returns `HTTP 401`, prepend `unset GITHUB_TOKEN` to the failing
command and retry — stale env-var workaround.

## Review process

Run the passes below **in parallel** using the Agent tool. Each pass
is independent and focused on one concern. After they finish,
aggregate.

If the PR diff is empty, stop and report "PR diff is empty — nothing
to review."

---

### Pass 1 — Extension hygiene

For every `contrib/<name>/` directory touched in the diff (added or
modified):

- **Name consistency.** `manifest.yaml` `metadata.name`,
  `pkg.yaml` `name`, and the directory name must all match. Conftest
  enforces this on the per-extension pair, but double-check for
  rename PRs where one file might lag.
- **Version bump.** If `pkg.yaml` (build steps, `finalize`,
  `dependencies`) or `rootfs/` payload changed, did
  `manifest.yaml` `metadata.version` bump? An unchanged version
  means consumers re-pulling the image get new bits silently — the
  manifest version is the only signal they have.
- **Talos compat.** Is `compatibility.talos.version` still sane
  given any new `dependencies:` against `PKGS` / `TOOLS`? A pin of
  `PKGS = v1.12.5` plus `compatibility.talos.version: ">= v1.8.0"`
  is almost certainly wrong.
- **Description / author.** Non-empty and meaningful (the conftest
  rule only requires ≥10 chars).
- **`/rootfs` finalize.** Present only if the build actually
  produces something under `/rootfs`. A scratch extension that
  finalizes a non-existent `/rootfs` will fail the build — but it
  might fail late (in CI on arm64 only, etc.).
- **Catalog entry.** New extension → was the table in `README.md`
  updated? Removed extension → was the row removed?

For added extensions, also: was the target wired into `.kres.yaml`
`spec.targets` AND the generated `Makefile`'s `TARGETS = …` line?
Both must be present (the second is a `make rekres` regenerate).

---

### Pass 2 — Build & release impact

- **`.kres.yaml` change?** Confirm the `Makefile` diff in this PR
  matches what `make rekres` would produce. Spot-check: if
  `spec.targets` lost or gained an entry, the `TARGETS = …` line in
  `Makefile` should reflect it. If they disagree, the author hand-
  edited or forgot to `make rekres`.
- **`PKGS` / `TOOLS` / `BLDR_RELEASE` bump?** These move every
  extension's base. Confirm in the PR description (or via the
  Talos release notes for that version line) that the bump is
  intentional and that breaking changes don't cascade into the
  pinned extensions.
- **Workflow change?** (`.github/workflows/*.yaml`)
  - Top-level `permissions:` still `contents: read`?
  - Per-job perms still narrow (only `contents: write`,
    `packages: write`, `id-token: write` where actually used)?
  - Any new third-party action SHAs pinned to a 40-char commit, not
    a floating tag?
  - Any new `curl | bash` install with no checksum verification?
- **`release-drafter.yml` change?** Labels in `version-resolver`
  still cover every category in `categories`? Missing alignment
  means PRs land without a version bump signal.

---

### Pass 3 — Supply chain & signing

This repo's whole pitch is "you can verify what you pull." Don't
let a PR erode that.

- **Cosign signing step still runs over every published image?**
  In `ci.yaml`'s `Sign published images` step, the per-extension
  loop reads `internal/extensions/image-digests` (which contains
  one line per target in `TARGETS`). If a new extension was added,
  signing covers it automatically — but verify the loop is still
  intact and `if: github.event_name != 'pull_request'` hasn't
  drifted.
- **Provenance / SBOM flags.** `CI_ARGS: --provenance=mode=max
  --sbom=true` must still be set on the build job. If anyone
  changed it to `--provenance=false` or dropped `--sbom`, block.
- **No secrets in the diff.** Grep the diff for tokens, keys,
  `BEGIN PRIVATE`, `ghp_`, `gho_`, `xox`, `AKIA`, `password:`,
  `secret:`. Even one false positive is fine — better paranoid.
- **Build artifacts checked in?** `_out/`, `*.log`, `*.tgz`,
  per-target `metadata.json` — these should be `.gitignore`d.
  Flag if present.

---

### Pass 4 — Schema, lint, CI status

- **`gh pr checks "$PR_NUM"` output.** Every required check
  green? A failing check is almost always a block. If a check is
  red, fetch the failed log (`gh run view --log-failed <run-id>`)
  and surface the actual failure — don't just say "CI failed."
- **`conftest test --policy policy` would pass locally?** If
  `policy/extension.rego` changed in this PR, re-run conftest
  against the fixtures (`contrib/*`, `extensions/_template`)
  mentally — does the new policy still pass every shipping
  extension? A stricter policy that doesn't cover its own fixtures
  is a self-inflicted CI failure waiting to happen.
- **`yamllint .` would pass?** New YAML files added — are they
  covered by the `.yamllint` ignore set, or do they need to pass
  the default config?
- **`shellcheck` clean?** New shell in `scripts/` or `hack/` — any
  unquoted `$var`, missing `set -euo pipefail`, `[ $x = ]`-style
  bugs?

---

### Pass 5 — Release notes & PR shape

Release Drafter consumes PR titles + labels to draft the next
release. A merged PR with an off-shape title fouls the release notes.

- **Title is short, present-tense, Conventional-Commits-ish.**
  `feat(<name>): add <name> extension` / `fix(<name>): pin
  PKGS for v1.11`. Match the voice in `git log main
  --pretty=format:%s | head -10`. Long, hesitant, or past-tense
  titles read poorly in a published changelog.
- **A version-resolver label is set.** `feature`, `enhancement`,
  `fix`, `bug`, `bugfix`, `chore`, `dependencies`, `documentation`,
  `major`, or `breaking`. Without one, Release Drafter defaults to
  `patch` (often wrong for `feat` PRs).
- **Body explains the *why*.** A two-line body is fine for a
  one-extension scaffold; a build-system or workflow change needs
  context the reader will want when the PR shows up in a release
  notes search six months later.
- **No "WIP" / "fixup!" / "squash!" commits left unsquashed.**
  If the merge strategy is squash-merge, this is cosmetic; if it's
  rebase-merge, it's a real problem.

---

## Aggregating findings

Collect into a single report:

```markdown
## Pre-merge review of PR #<NUM>

**Verdict:** [Block | Cautions | Clean]

**Blocks (do not merge):**
- [pass N] file:line — short description and concrete consequence.

**Cautions (consider before merge):**
- [pass N] file:line — short description.

**Confirmed safe:**
- N concerns ruled out after closer reading.

**CI snapshot:** <copy the `gh pr checks` summary line — green/red counts>.
```

Severity rubric:
- **Block** — failing CI; broken cosign step; provenance/SBOM
  disabled; secret in diff; `.kres.yaml` and `Makefile` out of
  sync; conftest would fail locally; missing extension metadata
  fields the policy enforces; schema-breaking change to a shipping
  extension without `metadata.version` bump.
- **Caution** — missing catalog entry; missing version-resolver
  label; PR title shape; unsquashed fixup commits; Talos compat vs
  PKGS pin mismatch worth confirming with the author.
- **Investigate** — if you can't determine severity from the diff
  alone (e.g., a `PKGS` bump and you don't know the upstream
  changelog), say so; do not guess.

If everything is clean, say so explicitly: `Verdict: Clean — safe to
merge.`

## What NOT to flag

- **Style.** YAML indentation, comment density, file organization —
  yamllint and conftest cover what matters; the rest is taste.
- **Refactoring suggestions.** "Could be a helper", "could be
  smaller" — not the merge-gate's job.
- **Missing tests.** This repo doesn't run image-content tests today
  (see Phase 1 vs Phase 2 of the audit). Don't ask the author to
  add a test framework as part of an unrelated PR.
- **Anything CI already enforces** (yamllint, shellcheck, conftest,
  bldr build, cosign sign). If CI is green and you trust the gates,
  trust the gates; surface the *gaps* CI can't see.
- **Anything the author can't fix in this PR** without dragging in
  unrelated scope (e.g., "we should adopt Renovate" — true, but
  belongs in its own PR).
- **Documentation tone or wording.** Block on factual errors and
  broken links; don't bikeshed prose.

## Tone

Match the project's calm, prose-first voice. Be specific about why
each finding matters — "missing version-resolver label, so this PR
won't bump the release" is useful; "needs a label" is not.

When you say **Clean**, mean it. A reviewer who reads "Clean — safe
to merge" and then finds a bug in production after merge loses trust
in this skill.

When you say **Block**, be concrete about what the author must
change. The author is going to read this and ask "what do I do
next" — answer that.
