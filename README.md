# K8s Sharing Session — Kubernetes Basics + Offensive Security Finale

A live-demo session on a local [kind](https://kind.sigs.k8s.io/) cluster: core Kubernetes concepts first, then a short offensive-security segment that turns one compromised pod into full cluster takeover — and then fixes it.

## Session structure (~75 min)

| # | Topic | Time | Files |
|---|---|---|---|
| 0 | Cluster & nodes | 5 min | `kind-config.yaml` |
| 1 | Pod | 5 min | `01-pod.yaml` |
| 2 | Deployment, ReplicaSet, labels, rolling updates | 10 min | `02-deployment.yaml` |
| 3 | Service (ClusterIP, DNS, NodePort) | 8 min | `03-service.yaml` |
| 4 | ConfigMap & Secret | 7 min | `04-config.yaml` |
| 5 | StatefulSet | 8 min | `05-statefulset.yaml` |
| 6 | HPA (finale of the basics) | 8 min | `06-hpa.yaml` |
| **7** | **Offensive security finale** | **12–15 min** | `security-demo/` |
| 8 | Wrap-up + teardown | 3 min | — |

## Runbooks

- **[`RUNBOOK.md`](RUNBOOK.md)** — the full basics demo. Every step: **Say** (concept) → **Type** (commands) → **Point out** (takeaway).
- **[`security-demo/RUNBOOK-SECURITY.md`](security-demo/RUNBOOK-SECURITY.md)** — the security finale, same format, every command tested against kind v1.34.

## The security finale (attack chain)

One story, two attack surfaces: *"remember the app we exposed on `localhost:30090`? imagine it had an RCE."*

1. **Stolen ServiceAccount token + over-granted RBAC** — the pod's identity is a JWT mounted as a file. From inside the pod: decode it, hit the API server with plain `curl`, and exfiltrate the DB password from a Secret (callback to step 4's "Secrets are just base64").
2. **Privileged pod → node escape → cluster takeover** — the SA can `create pods`, so deploy a `privileged` pod with `hostPath: /` pinned to the control-plane node, steal `/etc/kubernetes/admin.conf`, and use the cluster-admin kubeconfig from the laptop.
3. **Fix it in 60 seconds** — least-privilege RBAC, `pod-security.kubernetes.io/enforce=restricted`, `automountServiceAccountToken: false` — then re-run both attacks live and watch them get denied.

```
app pod (RCE) → SA token file → over-granted Role → privileged pod → node disk → admin.conf → cluster-admin
```

## Setup

```bash
./setup.sh                 # ~2 min: fresh k8s-demo cluster, images preloaded, metrics-server
kubectl top nodes          # should print numbers
```

The security segment needs nothing extra on the `k8s-demo` cluster (`curlimages/curl` is preloaded by `setup.sh`). To run it on any other kind cluster, just `cd security-demo && ./reset.sh` — the pod pulls the image from Docker Hub.

## Files

```
.
├── kind-config.yaml           # 1 control-plane + 2 workers, NodePort 30090 mapped to localhost
├── setup.sh                   # full cluster reset + image preload + metrics-server
├── RUNBOOK.md                 # basics demo runbook (steps 0–8)
├── 01-pod.yaml … 06-hpa.yaml  # demo manifests for steps 1–6
└── security-demo/
    ├── RUNBOOK-SECURITY.md    # detailed security demo script (S1–S3)
    ├── reset.sh               # security-demo reset (~10s)
    ├── 01-app.yaml            # the "vulnerable app" (fat ServiceAccount, token automounted)
    ├── 02-rbac.yaml           # the over-granted Role/RoleBinding — the actual misconfiguration
    ├── 03-escape-pod.yaml     # the "malicious" manifest: privileged + hostPath on control-plane
    └── 04-hardened.yaml       # reference: the fixed deployment (not applied by reset.sh)
```

## Teardown

```bash
kind delete cluster --name k8s-demo
```
