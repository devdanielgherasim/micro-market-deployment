# deployment

The apps-only GitOps repo. Four Helm charts — **catalog, orders, audit, micro-market-frontend** — plus the top-level per-environment values that ArgoCD's `microservices` ApplicationSet (created by `../kubernetes-infrastructure`'s Terraform) fans out across `dev`/`staging`/`prod`. Platform add-ons (Istio, cert-manager, monitoring, Keycloak, CloudNativePG, ...) are **not** here — see `../platform-gitops` for those. This repo owns only the 4 application workloads.

## Layout

```
catalog/                  orders/  audit/  micro-market-frontend/
  Chart.yaml
  values.yaml              # chart defaults
  templates/
    namespace.yaml
    deployment.yaml
    service.yaml
    serviceaccount.yaml
    configmap.yaml  secret.yaml
    hpa.yaml  pdb.yaml
    ingress.yaml            # renders a Gateway API HTTPRoute, not a k8s Ingress
    networkpolicy.yaml
    authorizationpolicy.yaml   # Istio AuthorizationPolicy
    peer-authentication.yaml   # Istio STRICT mTLS
    NOTES.txt  _helpers.tpl  tests/test-connection.yaml
environments/
  dev/{catalog,orders,audit,micro-market-frontend}-values.yaml
  staging/{...}-values.yaml
  prod/{...}-values.yaml
ci/global-values.yaml       # CI-only stand-in for what ArgoCD injects at sync time
.github/workflows/ci.yml
.checkov.yaml
```

None of the 4 `Chart.yaml`s declares a `dependencies:` block — the charts are self-contained, no vendored subcharts.

### The `environments/<env>/<app>-values.yaml` layout (Phase 10 restructure)

This top-level layout replaced an earlier, byte-identical-per-app `<app>/environments/<env>-values.yaml` structure. The restructure exists for one reason: it matches the ApplicationSet's `valueFiles: ['../environments/{{env}}/{{app}}-values.yaml']` convention exactly, and gives the CI promote stage (below) a single flat directory to write into instead of 4 scattered per-chart ones.

Each of the 12 files is a **thin overlay** — only the deltas for that environment, everything else falls back to the chart's own `values.yaml` defaults:

- `replicaCount`: 1 (dev) / 2 (staging) / 3 (prod).
- `autoscaling`: disabled in dev; enabled in staging (min 2/max 4) and prod (min 3/max 6).
- `resources`: tiered per environment.
- `global.domain`: `dev.danielgherasim.com` / `staging.danielgherasim.com` / `danielgherasim.com` (apex in prod) — drives the `HTTPRoute` hostname default in `ingress.yaml`.
- Log level via a new `extraEnv` list (appended to the chart's base `env` list by `deployment.yaml` — Helm replaces lists wholesale, so per-env log vars couldn't live in the base `env` list and vary at the same time): `QUARKUS_LOG_LEVEL=DEBUG` (dev) / `INFO` (staging, prod) for the three Quarkus services, `NEXT_PUBLIC_LOG_LEVEL` equivalent for the frontend.
- Demo seed data (dev + staging only, off in prod): `HIBERNATE_GENERATION=drop-and-create` + `HIBERNATE_LOAD_SCRIPT=import.sql`.
- `image.repository`/`image.tag` are **`REPLACED_BY_CI` placeholders** in every file — cloud registry paths differ per cloud (AWS ECR / Azure ACR / GCP Artifact Registry, see the comment block in each values file for the exact per-cloud path formula) so they can't be static, and the tag is exactly what the promote stage below writes.

`global.environment` and `global.keycloak.*` are also set per file but are currently vestigial — no template consumes them yet; only `global.domain` is functional today. Demo *users* (as opposed to demo *data*) are a Keycloak-realm concern owned by `../platform-gitops`, not toggleable from these charts.

## Gateway API ingress, Istio ambient, mTLS

Each chart's `ingress.yaml` renders a `gateway.networking.k8s.io/v1` `HTTPRoute` (not a core `networking.k8s.io/v1 Ingress`) attaching to the shared `Gateway` that `platform-gitops/platform/gateway` creates. Namespaces get the `istio.io/dataplane-mode: ambient` label (set by `../kubernetes-infrastructure`'s Terraform on the `microservices` namespace, and expected on the ApplicationSet's `micro-market-<env>` namespaces too) so Istio's ambient ztunnel dataplane picks up traffic automatically without sidecar injection. Every chart also renders a per-workload `AuthorizationPolicy` (default-allow only from its own namespace, extendable via `authorizationPolicy.allowedNamespaces`) and a STRICT `PeerAuthentication` (mTLS-only) — both are Istio `security.istio.io` CRDs, not native Kubernetes resources.

## CI pipeline (`.github/workflows/ci.yml`)

CI runs on GitHub Actions (migrated from GitLab CI, see
`Sources/plans/2026-07-08-gitlab-to-github-migration.md`). Jobs:

- `security-scan-gate`: calls the reusable workflow in `devdanielgherasim/micro-market-utilities` (CodeQL, gitleaks, dependency-review).
- `helm-lint`: `helm lint` on each of the 4 charts, both with defaults and against each of the 3 env value files (`CHARTS`/`ENVS` workflow env vars).
- `helm-template`: renders all 4×3 = 12 chart/env combinations into a shared `rendered/` artifact, using `ci/global-values.yaml` (a CI stand-in for the `global.domain`/`environment`/`keycloak.*` values that ArgoCD would actually inject as Application parameters at sync time — CI has no ArgoCD, so this file supplies realistic placeholders purely so the rendered manifest shape matches what ArgoCD would really produce) plus `--set-string image.repository=example.azurecr.io/<chart>` (filling the intentionally-blank `REPLACED_BY_CI` placeholder) and `--namespace microservices` (without it, local `helm template` would default `.Release.Namespace` to `default`, a CI artifact — ArgoCD sets the real destination namespace at sync time).
- `kubeconform` + `checkov` (both depend on `helm-template`): validate the rendered output. `kubeconform` uses `-ignore-missing-schemas` plus the `datreeio/CRDs-catalog` as an extra schema source (covers Gateway API's `HTTPRoute` and other common CRDs); core Kubernetes kinds are always validated strictly.
- `promote-dev` / `promote-staging` / `promote-prod` (see below).

### `.checkov.yaml`

Framework `kubernetes`, scanning the `rendered/` output. One `skip-path` (`templates/tests/` — Helm's auto-generated `helm test` smoke-test hook pods, never synced by ArgoCD in steady state) and 4 `skip-check` IDs, each with a documented reason: `CKV_K8S_43` (no image-digest pinning — CI already tags by immutable commit SHA), `CKV_K8S_35` (secrets as env vars — owned by the service repos' MicroProfile Config interface, flagged as a coordinated follow-up rather than silently accepted), `CKV_K8S_40` (high-UID requirement — can't safely change from the Helm side without knowing the actual image UID), `CKV_K8S_21` (default-namespace false positive — idiomatic Helm; the real namespace comes from ArgoCD's `destination.namespace`, not from a hardcoded `metadata.namespace`). Real, fixable gaps were fixed directly instead of skipped — e.g. all 4 charts run with `readOnlyRootFilesystem: true` plus a `/tmp` `emptyDir` mount, and `serviceAccount.automount` defaults to `false` (a drift where every `environments/*-values.yaml` had it flipped back to `true` was corrected).

### The `promote-*` jobs — how a built image actually reaches a running environment

This is the mechanism that gets a built-and-signed image from a service repo's CI into a real cluster.

- **`promote-dev`** — triggered by a `repository_dispatch` event of type `image-promoted`. It is *not* triggered by a normal push to this repo; it's fired by each service repo's own `trigger-deployment-promotion` job (part of `devdanielgherasim/micro-market-utilities`' `image-supply-chain.yml` reusable workflow, runs after that service's `cosign-verify` gate passes) calling the **GitHub REST API** (`POST /repos/{owner}/{repo}/dispatches`) against this repo, authenticated with a fine-grained PAT (`DEPLOYMENT_DISPATCH_PAT`, scoped only to this repo with `Contents: Read and write`) and carrying `PROMOTED_APP`/`PROMOTED_IMAGE_REPOSITORY`/`PROMOTED_IMAGE_TAG` in the event payload. `promote-dev` writes that `(PROMOTED_APP, PROMOTED_IMAGE_TAG)` pair into `environments/dev/<PROMOTED_APP>-values.yaml`'s `.image.tag` via `yq -i`, and commits+pushes to `main` using the workflow's own `GITHUB_TOKEN` (`permissions: contents: write` — no PAT needed for a same-repo push) with `git config user.name "github-promote-bot"`.
- **`promote-staging`** / **`promote-prod`** — triggered via `workflow_dispatch` (manual, `promote-environment: staging|prod`), gated to the `staging`/`production` GitHub Environments (both configured with a required reviewer). They copy the *current* tag forward (`dev → staging`, `staging → prod`) for all 4 charts in one job, failing fast with a clear error if the source file's tag is still the `REPLACED_BY_CI` placeholder (i.e. nothing has been promoted to dev yet).

Every write-back commit is a no-op exit (not a failure) if nothing actually changed, so re-runs are idempotent.

`DEPLOYMENT_DISPATCH_PAT` is set on all 4 service repos (a human-created fine-grained PAT — GitHub has no API to mint one non-interactively, see `utilities/scripts/bootstrap-github.sh`'s header). Without it, a service repo's `trigger-deployment-promotion` job fails and `promote-dev` never fires.

One documented cosmetic quirk: `yq`'s `-i` round-trip is not byte-minimal — it collapses blank lines between mapping entries and re-flows trailing `#` comment spacing on any write (a `go-yaml-v3` limitation, no CLI flag fixes it). The first promote against a given values file will include that whitespace churn alongside the real `.image.tag` change; verified locally that `.image.repository` and every other key are otherwise untouched.
