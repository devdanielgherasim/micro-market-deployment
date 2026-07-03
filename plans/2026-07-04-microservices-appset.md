---
title: Microservices ApplicationSet + per-env values (Phase 10 Tasks 27-28)
status: completed
created: 2026-07-04
updated: 2026-07-04
---

# Microservices ApplicationSet + per-env values

## Context
Phase 10 (Tasks 27-28) of the multi-cloud overhaul (parent plan:
`../../plans/2026-07-03-multicloud-platform-overhaul.md`). Two repos are touched:

- `kubernetes-infrastructure/terraform/kubernetes/{bootstrap.tf,variables.tf}` —
  add a `kubernetes_manifest` ArgoCD **ApplicationSet** that deploys the 4
  microservice charts across 3 envs; delete the dead `gitops_applications`
  variable (only referenced by itself + a superseded plan md).
- `deployment/` — restructure per-env values from
  `deployment/<app>/environments/<env>-values.yaml` (byte-identical placeholders)
  to the plan's target layout `deployment/environments/<env>/<app>-values.yaml`,
  and populate them with **real per-env deltas**.

Key discoveries from investigation (2026-07-04):
- HPA templates (`templates/hpa.yaml`, `autoscaling.*` values) ALREADY exist in
  all 4 charts — no new template needed. Dev disables HPA (`autoscaling.enabled:
  false` + `replicaCount`), staging/prod enable it.
- `global.environment` and `global.keycloak.*` are consumed by NO template
  (vestigial metadata). Only `global.domain` is used — as the default HTTPRoute
  hostname in `templates/ingress.yaml` (`default $.Values.global.domain .`). So
  per-env hostnames are driven cleanly by setting `global.domain` per env and
  leaving `httpRoute.hostnames: [""]` to default to it. All 4 apps share one
  hostname per env (path-based routing: /api/products, /api/orders, /api/audit, /).
- Quarkus log level: `application.properties` hardcodes `quarkus.log.level=INFO`,
  but env var `QUARKUS_LOG_LEVEL` overrides it (MicroProfile env ordinal 300 >
  properties). No app change needed.
- Frontend log level: `utils/logger.ts` reads `process.env.NEXT_PUBLIC_LOG_LEVEL`.
  Wire it via the frontend configMap (build-time-inlining caveat for the client
  bundle noted in report).
- Seed/demo DATA: `application.properties` has
  `HIBERNATE_GENERATION`/`HIBERNATE_LOAD_SCRIPT` + an `import.sql`. Seeding only
  runs with drop-and-create/create semantics, so it is only coherent in dev.
  Demo USERS are a Keycloak-realm concern already handled dev-only in
  platform-gitops (`enable_keycloak_demo_users`) — OUT OF SCOPE here. See report.

Design for per-env env vars (Helm REPLACES lists across value files, so we can't
partially override the base `env:` list): move the per-env-varying vars out of
each Quarkus chart's base `env:` into a new `extraEnv: []` list that the
deployment template appends. Env files then set only `extraEnv` (a list only the
env file populates -> no merge conflict). Frontend uses a configMap (a map ->
deep-merges), so per-env keys are overridden directly.

image.repository/tag: per-cloud registry paths (AWS ECR / Azure ACR / GCP AR)
can't be encoded statically for all 3 clouds in one file, and account-specific
parts aren't known here. Both set to `REPLACED_BY_CI` placeholders with a comment
documenting the per-cloud build.sh formula; tag is written back by Task 29's
promote stage. Documented as a design call.

CI note: `deployment/.gitlab-ci.yml`'s `helm-lint`/`helm-template` jobs reference
the OLD `$chart/environments/$env-values.yaml` path. The mandated restructure
forces a minimal path-literal update there (NOT the promote stage, NOT stage/gate
logic). Flagged in report.

## Tasks
- [x] 1. Write ApplicationSet `kubernetes_manifest.argocd_microservices_appset`
  in `bootstrap.tf` (matrix generator: apps list x envs list; fasttemplate
  `{{app}}`/`{{env}}` vars; namespace `micro-market-{{env}}`); added
  `argocd_deployment_target_revision` var; deleted dead `gitops_applications`
  var. `terraform fmt -check` clean (stable 1.15.7).
- [x] 2. Restructured dirs via `git mv` (12 files, rename history preserved),
  then rewrote contents. Old per-app `environments/` dirs removed.
- [x] 3. Chart base changes done (4 charts): removed CORS_ORIGINS/
  DEPLOYMENT_ENVIRONMENT/HIBERNATE_GENERATION/HIBERNATE_LOG_SQL/
  OTEL_TRACES_SAMPLER_ARG from base `env`; added `extraEnv: []`; added `extraEnv`
  append block to all 4 `deployment.yaml`; added `NEXT_PUBLIC_LOG_LEVEL` to
  frontend base configMap.
- [x] 4. Populated 12 env value files with real deltas (thin overlays).
- [x] 5. Minimal CI path update in `.gitlab-ci.yml` (lint + template `-f` paths
  only; stages/gates untouched).
- [x] 6. Verified: helm lint + template all 12 combos PASS; rendered per-env
  diffs confirmed (dev replicas:1/no-HPA/DEBUG/seed; staging+prod HPA on; prod
  apex host + `update` + no seed script; frontend log levels + API URLs vary);
  `terraform fmt -check` exit 0 (stable 1.15.7); no duplicate env names in
  render; `git diff --check` clean both repos; no `gitops_applications` refs
  remain in terraform/; only deployment (21) + kubernetes-infrastructure (2)
  touched (the 1 micro-market-frontend change is the pre-existing ProductList.tsx
  Codex rework the parent plan says to leave alone — untouched by me).

## Resume notes
COMPLETE (2026-07-04). All 6 tasks done and verified.

### Design calls made
- Per-env env vars for Quarkus use a new `extraEnv` list appended by the
  deployment template (base `env` had the varying vars removed) because Helm
  REPLACES lists across value files — an overlay can't partially patch `env`.
- Hostnames driven by `global.domain` (the ingress.yaml default mechanism) with
  base `httpRoute.hostnames: [""]` left in place; one hostname per env, path-based
  routing across the 4 apps.
- `global.environment`/`global.keycloak.*` are set in the values files but are
  consumed by NO template today (vestigial metadata); only `global.domain` is
  functional. Documented, not "fixed", to avoid scope creep.
- image.repository AND image.tag are `REPLACED_BY_CI` placeholders (with per-cloud
  formula comments) — a single static file can't hold AWS/Azure/GCP registry paths
  (account-specific), and tag is Task 29's write-back target.
- ApplicationSet uses classic fasttemplate (`{{app}}`/`{{env}}`), matrix of two
  list generators; no goTemplate.

### Known limitations / cross-repo dependencies (out of my scope)
- Demo/seed USERS are a Keycloak-realm concern handled dev-only in platform-gitops
  (`enable_keycloak_demo_users`); the app charts cannot toggle Keycloak users. What
  the app charts DO toggle is demo DATA via `HIBERNATE_GENERATION=drop-and-create`
  + `import.sql` (dev+staging; off in prod). Caveat: import.sql only loads under
  drop-and-create, so seeded rows reset on pod restart — acceptable for the
  ephemeral spin-up→demo→destroy model but noted.
- The env files reference secrets/configmaps (`*-db-secret`, `keycloak-secret`,
  `keycloak-config`) that must exist in each `micro-market-{env}` namespace. Today
  bootstrap.tf creates `keycloak-config` only in the `microservices` namespace;
  provisioning these per-env (via ESO ExternalSecrets in platform-gitops) is a
  prerequisite for the apps to actually run, and is outside this task's scope.
- Frontend `NEXT_PUBLIC_LOG_LEVEL` is wired via configMap; client-bundle
  NEXT_PUBLIC_* values are normally build-time-inlined, so the runtime override
  fully applies only to the standalone server side.
- One necessary CI touch: `deployment/.gitlab-ci.yml` lint/template `-f` path
  literals updated to the new layout (NOT stage/gate logic, NOT the promote stage
  reserved for Task 29) — unavoidable consequence of the mandated file move.

## Verification
- `helm lint <chart> -f environments/<env>/<chart>-values.yaml` and
  `helm template` for all 4 charts x 3 envs render clean; rendered output shows
  correct per-env replica counts / HPA presence / hostnames / log levels.
- `terraform fmt -check -diff` clean on `kubernetes-infrastructure/terraform/kubernetes`
  using the stable winget Terraform 1.15.7 (NOT chocolatey alpha on PATH).
- `git diff --check` clean in both repos; no other repo touched.
- ApplicationSet matrix-generator var syntax matches ArgoCD docs.
