# infra

Infra team repo of the KubernetesWorkloadManagement PoC (public, assumption A1).

| Folder | Content |
|---|---|
| `argocd/` | `root-app.yaml` (App-of-Apps, applied once by hand), `apps/` (AppProjects and child Applications) |
| `platform/` | namespace `platform` (`EA-0000`, `shared`), `approval-gate/` (gate RBAC; `hook/` = the gate Job that app builds pull in), `garage/` (S3 store, Phase 1 step 1.8) |
| `infraBackbone/v1.0.0/` | standard backbone v1.0.0; `sb-1-namespace-baseline/` = label policy (ADR-19) |
| `appCustomizedInfra/<app>/` | per-app infra block, copied and tagged; pulled by `enterpriseApps` as a remote base at a tag |

Secrets and evidence never enter this repo (`.gitignore`).
