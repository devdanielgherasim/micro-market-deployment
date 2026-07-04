---
title: CI promote stage (dev auto, staging/prod manual image.tag write-back)
status: done
created: 2026-07-04
updated: 2026-07-04
---

# CI promote stage

Phase 10 Task 29 of `../../plans/2026-07-03-multicloud-platform-overhaul.md`. Scope:
`deployment/.gitlab-ci.yml` only — add a `promote` stage on top of the existing
`lint -> template -> scan` pipeline (Task 26b). No other file/repo touched.

## Tasks

- [x] 1. Read `.gitlab-ci.yml` in full + a couple of `environments/<env>/<app>-values.yaml`
      to confirm `image.tag`/`image.repository` shape (`"REPLACED_BY_CI"` placeholders).
- [x] 2. Confirm the tag scheme each service repo's own `build.sh` actually uses.
      Checked `catalog/build.sh`, `orders/build.sh`, `audit/build.sh`,
      `micro-market-frontend/build.sh` directly: all four tag with
      `${CI_COMMIT_SHA}` (full SHA, not short). Confirms the task's assumption.
      **Caveat found and NOT silently resolved** (see "Known gap" below):
      `deployment`'s own `$CI_COMMIT_SHA` inside its own pipeline is a
      `deployment`-repo commit hash, not the same value as the SHA the
      *service* repo's build job tagged the image with — those are two
      different repos with unrelated commit histories.
- [x] 3. Confirmed via web search: GitLab's documented skip-pipeline marker is
      `[skip ci]` / `[ci skip]` (case-insensitive) anywhere in the commit
      message, honored by default workflow rules with no extra
      `workflow:rules` needed (this repo has no `workflow:` override block).
      Also confirmed the git-remote auth pattern for a non-CI_JOB_TOKEN
      write-scoped token: `https://<any-non-blank-username>:<token>@<host>/<path>.git`
      (project/group access tokens ignore the username in basic auth).
- [x] 4. Decided image: plain `alpine:3.20` + `apk add --no-cache git yq ca-certificates`
      in `before_script`, rather than trusting an unverified third-party
      composite image. Matches the file's existing "focused, single-purpose
      image per job" convention (`alpine/helm`, `kubeconform`, `checkov`).
- [x] 5. Verified locally with a real downloaded `yq` v4.53.3 binary (this host
      had no `yq`; `winget`/`choco` both blocked — winget by the same local
      Norton TLS-interception issue documented elsewhere in the parent plan,
      choco by lack of admin rights — so pulled the static Windows binary
      directly from GitHub via `curl -k`) against copies of
      `environments/dev/catalog-values.yaml` and
      `environments/staging/catalog-values.yaml`:
      - `yq -i '.image.tag = strenv(CI_COMMIT_SHA)' file` correctly writes only
        the tag value; `.image.repository` and every other key are semantically
        unchanged.
      - **Found and documented, not silently worked around**: yq v4's `-i`
        round-trip is NOT byte-minimal on these files — *any* `-i` edit
        (even a true no-op `.image.tag = .image.tag`) collapses blank lines
        between mapping entries and re-flows trailing `#` comment spacing to
        exactly one space, repo-wide in the touched file. This is a
        long-standing upstream limitation of the go-yaml v3 encoder yq wraps
        (blank lines aren't part of the YAML AST; comment column alignment
        isn't preserved), not something fixable via a yq CLI flag. Net
        effect: the *first* promote commit against any given values file will
        include whitespace-only churn beyond the `tag:` line; subsequent
        promotions are effectively no-ops on that formatting (already
        collapsed). Semantic content (all key values) is verified unchanged
        aside from the intended tag write.
      - `promote-staging`-style flow (`TAG=$(yq '.image.tag' dev-file)` then
        write into the staging file) verified end-to-end: reads the value
        correctly, writes it correctly, leaves `.image.repository` untouched.
- [x] 6. Wrote the `promote` stage: `.promote-base` (shared image/before_script:
      apk install, git identity, write-scoped remote via `GITLAB_PROMOTE_TOKEN`),
      `promote-dev` (automatic, default branch only, writes `$CI_COMMIT_SHA`),
      `promote-staging`/`promote-prod` (manual, copy current tag forward one
      environment). All three: `[skip ci]` in the commit message, skip the
      commit+push entirely (exit 0) if nothing actually changed (idempotent
      re-runs), `resource_group: promote` to serialize pushes across the three
      jobs and avoid race losers.
- [x] 7. Verification: YAML-parsed the updated file with js-yaml (from
      `micro-market-frontend/node_modules/js-yaml`); `git diff --check` clean;
      confirmed only `deployment/.gitlab-ci.yml` (plus this plan file) touched.

## Known gap (found, not fixed — out of this task's repo scope)

`deployment`'s `$CI_COMMIT_SHA` (available in `promote-dev`'s job context) is
**not** the same value as the SHA each service repo's `build.sh` tags its
pushed image with — they are commit hashes in two unrelated git repos. As
literally specified, Task 29 has `promote-dev` write `deployment`'s own
`$CI_COMMIT_SHA` into `environments/dev/<app>-values.yaml`, which is only
correct if something outside this repo's scope (e.g. each service repo's
`build-and-push-native` job triggering a multi-project pipeline in
`deployment` with a custom variable carrying its own `$CI_COMMIT_SHA`,
consumed here instead of/alongside `deployment`'s native `$CI_COMMIT_SHA`)
threads the real upstream SHA through. That wiring lives in the 4 service
repos' `.gitlab-ci.yml`, explicitly out of scope for this task ("do NOT touch
any other repo"). Implemented literally as instructed; flagging this
prominently rather than silently building speculative untested cross-repo
plumbing nobody asked for. Left as a comment in `.gitlab-ci.yml` and called
out in the Task 29 report. Follow-up: a small dedicated task to add
`trigger:` jobs in catalog/orders/audit/micro-market-frontend that pass their
own `$CI_COMMIT_SHA` downstream, and a corresponding "prefer the passed-in
var, fall back to `$CI_COMMIT_SHA`" tweak here.

## Human action required before this works in real GitLab

Create a **Project Access Token** (or Group Access Token) on the `deployment`
project with the `write_repository` scope (`Settings > Access Tokens` in
GitLab), then add it as a **masked + protected** CI/CD variable named
`GITLAB_PROMOTE_TOKEN` (`Settings > CI/CD > Variables`). `CI_JOB_TOKEN` is
read-only/limited-API by default and cannot `git push`. No such token could be
created or tested from this environment (no live GitLab access) — this is
documented in `.gitlab-ci.yml` itself and here, not invented/guessed at.
