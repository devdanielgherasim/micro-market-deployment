---
status: done
created: 2026-07-03
updated: 2026-07-03
owner: codex
repo: deployment
objective: Harden Helm charts for production-ready AWS-first GitOps deployment.
superseded-by: ../../plans/2026-07-03-multicloud-platform-overhaul.md
---

> **Superseded 2026-07-03**: follow-up work is absorbed into the workspace-root plan
> `Sources/plans/2026-07-03-multicloud-platform-overhaul.md` (all-clouds-equal strategy;
> the chart hardening done here is kept and committed in its Phase 1).

# Production Chart Hardening

## Context
- This repo is the ArgoCD GitOps source for `catalog`, `orders`, `audit`, and `micro-market-frontend`.
- AWS is the reference production cloud; Cloudflare is DNS-only/free-tier for `danielgherasim.com`.
- Backups and disaster recovery are out of scope.
- The Kubernetes platform repo now provides AWS Load Balancer Controller, ExternalDNS, cert-manager DNS-01, External Secrets Operator, and AWS `gp3` storage.
- App charts currently have basic deployments/services/ingress/HPA, but production workload hardening is incomplete.

## Tasks
- [x] Add workload hardening defaults across app charts.
- [x] Add frontend ingress/domain/certificate defaults compatible with Cloudflare DNS-only.
- [x] Add chart validation commands and record exact results.
- [x] Review whether per-environment values need differentiated production settings.

## Decisions
- Do not modify app source code in this slice.
- Keep chart changes opt-in or conservative where restrictive policies can break runtime traffic.
- Keep Cloudflare WAF, paid products, backups, and disaster recovery out of scope.

## Validation
- `helm version` initially failed in the managed shell because `helm` was not recognized.
- Installed/upgraded Helm with WinGet; approved shell now resolves `helm.exe` under `C:\Users\adria\AppData\Local\Microsoft\WinGet\Links`.
- `helm version` passed with Helm v4.2.2.
- `helm lint .` passed for `catalog`, `orders`, `audit`, and `micro-market-frontend`; each chart only reports the non-failing informational recommendation to add a chart icon.
- `helm template catalog .`, `helm template orders .`, `helm template audit .`, and `helm template micro-market-frontend .` passed.
- Frontend rendering initially exposed empty deployment lifecycle fields; added `revisionHistoryLimit`, `progressDeadlineSeconds`, and `minReadySeconds` to frontend values and re-rendered successfully.
- `git diff --check` passed; Git still warns that LF files will be normalized to CRLF when Git touches them.
- Reviewed GitOps ApplicationSet parameters in the Kubernetes infrastructure repo. Per-environment chart files can remain lightweight because Terraform-managed ArgoCD parameters now inject environment, domain, ingress host/TLS host, frontend public URLs, and provider-specific image repositories.

## Next Steps
- Continue with a focused runtime network policy review after chart manifests are applied to a real cluster, because exact DNS/PostgreSQL/Keycloak egress restrictions should be verified against live traffic.
