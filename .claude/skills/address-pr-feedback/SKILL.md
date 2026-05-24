---
name: address-pr-feedback
description: Walk through review comments and failed CI checks on the current branch's PR, propose a fix per finding, and stage it for the author to review BEFORE committing. One pause-and-review cycle per finding. Use when the user says "address PR feedback", "fix the PR comments", "go through the review", or after a `gh pr checks` shows failures and the author wants to work through them one at a time.
disable-model-invocation: true
---

# Address PR Feedback

Walk the current branch's PR comments + failed CI checks one finding at a
time. For each finding: discuss the bug, propose a fix, make the edits,
run local gates, **stage the changes**, and **stop for author review**
BEFORE committing. The author's go-ahead drives every commit; the skill
never auto-commits, never auto-pushes.

## Apply when
- The user says "address PR feedback", "fix the PR comments", "go
  through the review", or "fix the CI failures."
- The current branch has an open PR (`gh pr view` returns a PR).
- Either: review comments exist (`gh api .../pulls/<n>/comments`), CI
  checks are failing (`gh pr checks` non-zero), or both.

## Do not apply when
- The branch has no open PR — direct the user to open one first.
- The PR is on `main` directly — refuse; this skill operates on feature
  branches.
- The author wants a single squashed commit covering all findings —
  this skill specifically does one-commit-per-finding for review
  granularity. Override by skipping the skill.

## Inputs to gather

Run these in parallel at the start. Cache the results — re-fetching
between findings is unnecessary unless the author pushed in the
meantime.

```bash
# Branch and PR identity.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
PR_NUM="$(gh pr view --json number --jq .number 2>/dev/null)"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

# Review comments (line-anchored; what reviewers wrote inline).
gh api "repos/$REPO/pulls/$PR_NUM/comments" \
    --jq '.[] | {file: .path, line: (.line // .original_line), body: .body, author: .user.login, in_reply_to: .in_reply_to_id, id: .id}'

# Top-level PR comments (general discussion, less common but worth checking).
gh api "repos/$REPO/issues/$PR_NUM/comments" \
    --jq '.[] | {body: .body, author: .user.login, id: .id}'

# CI checks. Failing rows are the second target.
gh pr checks "$PR_NUM"
```

If `gh` returns `HTTP 401`, the operator likely has a stale
`GITHUB_TOKEN` env var overriding the keychain. Prepend `unset
GITHUB_TOKEN` to the failing command and retry.

## Triage step

Before walking findings, **enumerate them in a numbered list to the
author** with file:line, severity (if the comment carries one), and a
one-line summary. Ask the author to confirm the order and call out any
findings they want to skip or defer.

Group rules:
- **Order by severity then file**: critical first, medium next, low
  last; within a tier sort by file path so changes to the same file
  cluster.
- **De-duplicate**: if two reviewers flagged the same line, treat as
  one finding.
- **Pre-existing convention findings** (the reviewer flags a pattern
  that already exists elsewhere in the repo) get flagged in the triage
  list with a "**Reject?**" suggestion. Don't silently skip them; the
  author decides.

The author's confirmation kicks off the per-finding loop.

## Per-finding loop

For each finding the author confirms, run this exact sequence:

1. **Re-state the finding.** Include file:line, severity, and the
   reviewer's prose verbatim (or a faithful summary if it's long).
   Cite the diff hunk if the comment is line-anchored.

2. **Confirm the bug.** Trace the code path or config, reason about
   whether the reviewer is correct, and *say so explicitly* — agree,
   disagree, or "agree on the symptom, disagree on the proposed fix".

3. **Propose the fix.** Brief: 2-4 sentences naming the file(s) and
   the shape of the change. If two paths are reasonable (e.g.,
   "document only" vs "code fix"), present both with a recommendation.
   The author picks before any code is written.

4. **Make the edits.** Use `Edit` / `Write` tools as appropriate.
   Match the project's existing patterns — look at neighboring
   extensions (`contrib/<name>/`) for precedent on `manifest.yaml` /
   `pkg.yaml` shape, and at `.kres.yaml` / `Makefile` for build wiring.

5. **Run local gates** narrowed to the changed area:
   - `yamllint .` if any YAML changed (`.kres.yaml`, `manifest.yaml`,
     `pkg.yaml`, workflows, release-drafter config).
   - `shellcheck scripts/*.sh hack/*.sh` if any shell script changed.
   - `conftest test --policy policy <files>` (per-file) and
     `conftest test --policy policy --combine <dir>/manifest.yaml
     <dir>/pkg.yaml` (cross-file) if a `manifest.yaml` or `pkg.yaml`
     changed.
   - `make rekres` if `.kres.yaml` changed — verify the regenerated
     `Makefile` is checked in.
   - `make <extension-name> PLATFORM=linux/amd64` if an extension's
     `pkg.yaml` or build steps changed. (Requires docker buildx; if
     unavailable locally, say so and let CI verify.)
   - `./scripts/resolve-extension.sh <name> <tag>` if the catalog
     resolution path changed.
   Report each result inline. If anything's red, fix it before
   continuing — never stage a broken state for the author.

6. **Stage the change.** `git add` the specific files (no `git add
   -A`, no `git add .`). Show `git status --short` and the *diff*
   (`git diff --cached --stat` and `git diff --cached` for small
   diffs; `--stat` only for large ones).

7. **STOP. Do NOT commit.** Hand back to the author with a
   one-paragraph summary of what was done and a literal "Ready for
   your review — give me the go-ahead to commit, request changes, or
   say `unstage`." This is the load-bearing pause.

8. **On author's go-ahead**: commit with a Conventional Commits-shape
   message. One commit per finding unless the author asks to squash.
   Match the project's existing commit-message voice (sample `git log
   main --pretty=format:%s | head -10`). End with the standard
   `Co-Authored-By` trailer.

9. **On author's request changes**: iterate. Don't move to the next
   finding until this one is committed-or-skipped.

10. **On author's `unstage`**: `git restore --staged` and treat the
    finding as deferred. Move on; report at the end.

## Failed CI checks

CI failures are findings too, just with a different source. Treat each
failing job as one finding with the same loop above:

1. **Re-state** with the job name and the URL from `gh pr checks`.
2. **Diagnose**: fetch the job's log via `gh run view --log-failed
   <run-id>` (the run-id is the rightmost column of `gh pr checks`).
   Show the relevant lines (not the whole log).
3. **Propose a fix** — usually a one- or two-file change. Common
   culprits in this repo: yamllint failures, shellcheck warnings in
   `scripts/` or `hack/`, conftest violations against
   `policy/extension.rego` (most often a name mismatch between
   `manifest.yaml` `metadata.name` and `pkg.yaml` `name`, or a
   missing/short `metadata.description`), missing target in
   `.kres.yaml` (regenerate with `make rekres`), bldr/buildx errors
   from `pkg.yaml`, or pin drift in `PKGS`/`TOOLS`.
4. **Make the edits**, **run gates**, **stage**, **stop**.

If a CI failure is genuinely transient (flaky runner, ghcr.io
hiccup, registry pull timeout), say so and offer to push an empty
`chore: re-trigger CI` commit — but only on the author's go-ahead,
and only after they've confirmed the failure is flaky.

## After the loop

Once every confirmed finding is either committed or explicitly
deferred:

1. **Show the commit list** added during this session: `git log
   origin/$BRANCH..HEAD --oneline` (commits not yet pushed).
2. **Run a final repo-wide sweep**: `yamllint .` at minimum; if any
   `pkg.yaml` changed and docker buildx is available, build every
   touched extension on `linux/amd64`.
3. **Ask before pushing.** "Ready to push? `git push origin
   $BRANCH`?" — never auto-push. The author may want to amend, rebase,
   or batch with other work first.
4. **On push go-ahead**: push, then `gh pr checks --watch=0` snapshot
   to confirm CI is starting. Print the PR URL.
5. **Summarize the session**: which findings were committed (with
   commit hashes), which were rejected/deferred, and any follow-ups
   that came up.

## What NOT to do

- **Don't commit without the author's explicit go-ahead.** The whole
  point of this skill is the pause-for-review step.
- **Don't `git add -A` / `git add .`** — only `git add <specific
  files>`. Stray files outside the finding's scope leak into the
  commit otherwise.
- **Don't squash findings into one commit** unless the author asks —
  one commit per finding is the contract.
- **Don't auto-push.** Push happens at the end on confirmation.
- **Don't run destructive git operations** (force-push, reset --hard,
  branch -D) unless the author explicitly asked.
- **Don't ignore a finding silently.** If the author wants to skip
  one, they say so explicitly; mark it deferred in the final summary.
- **Don't fix beyond the finding's scope.** A drive-by formatting
  change in an unrelated file leaks into the commit and obscures the
  review intent.
- **Don't hand-edit the generated `Makefile`.** It carries a "THIS
  FILE WAS AUTOMATICALLY GENERATED BY KRES" banner. Change `.kres.yaml`
  and run `make rekres` instead.

## Tone

Use the same calm, prose-first voice the project's other skills use.
Direct, honest about disagreement (the `confirm` step matters most
when you genuinely think the reviewer is wrong), and concise — the
author is reading this in the middle of a review cycle, not consuming
it as documentation.

When you reject a finding, say so plainly with the reasoning. The
author is empowered to override your reject, but they can't override
what you didn't surface.
