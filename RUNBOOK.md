# K8s Basics — Live Demo Runbook

Each step: **Say** (concept) → **Type** (commands) → **Point out** (the takeaway).

## Before the talk

```bash
./setup.sh            # ~2 min: fresh cluster, images preloaded, metrics-server installed
kubectl top nodes     # should print numbers (wait ~1 min after setup if not)
```

- `kubectl version` client and server should be within 1 minor version (`brew upgrade kubectl`).
- Big terminal font. Split into two panes:
  - **Left:** commands
  - **Right:** `watch -n1 kubectl get pods -o wide --show-labels` (audience sees pods appear and die live)
- Need a full reset at any point? Run `./setup.sh` again.

---

## 0. Cluster & Nodes (~5 min)

**Say:** A cluster is a set of machines (nodes). The control plane is the brain that decides; worker nodes are the muscle that run containers. kind runs each "node" as a Docker container on this laptop.

```bash
cat kind-config.yaml
kubectl get nodes -o wide
docker ps                              # the 3 "nodes" are just containers
kubectl get pods -n kube-system        # the control plane itself runs as pods
```

**Point out:** `etcd` (database), `kube-apiserver` (front door, every kubectl call goes here), `kube-scheduler` (picks a node for each pod), `kube-controller-manager` (keeps actual state = desired state).

---

## 1. Pod (~5 min)

**Say:** A Pod is the smallest unit: one or more containers sharing an IP. Two ways to create things: imperative (a command) and declarative (a YAML file describing desired state).

```bash
kubectl run nginx --image=nginx:1.27   # imperative
cat 01-pod.yaml                        # walk through: apiVersion, kind, metadata, spec
kubectl apply -f 01-pod.yaml           # declarative
kubectl get pods -o wide               # pod IP + which node it landed on
kubectl describe pod my-pod            # scroll to Events: scheduled -> pulled -> started
kubectl logs my-pod
kubectl exec -it my-pod -- sh          # inside the container; try: nginx -v, then exit
kubectl delete pod nginx my-pod
kubectl get pods
```

**Point out:** The pod is gone forever. Nothing brings it back. A bare pod doesn't heal itself, which is why we need Deployments.

---

## 2. Deployment, ReplicaSet & Labels (~10 min)

**Say:** A Deployment says "I want N copies of this pod." It creates a ReplicaSet, which keeps exactly N pods alive. Labels are key/value tags; a selector is a query over labels.

```bash
cat 02-deployment.yaml                 # highlight selector.matchLabels == template.labels
kubectl apply -f 02-deployment.yaml
kubectl get deploy,rs,pods --show-labels
kubectl describe pod <web-pod>         # "Controlled By: ReplicaSet/web-..."
```

**Point out:** Chain Deployment → ReplicaSet → Pods. Pod names = RS name + random suffix. `pod-template-hash` label ties pods to their RS.

**Self-healing:**
```bash
kubectl delete pod <web-pod>           # watch right pane: replacement appears instantly
```

**Scaling:**
```bash
kubectl scale deploy web --replicas=5
kubectl get pods -o wide               # spread across both workers
```

**Labels are the glue:**
```bash
kubectl label pod <web-pod> app-       # remove the app label
kubectl get pods --show-labels
```

**Point out:** The RS now counts only 4 matching pods, so it creates a 5th. The unlabeled pod keeps running but is no longer managed by anyone. Ownership is decided purely by labels. (Leave it running; it comes back in step 3.)

**Rolling update & rollback:**
```bash
kubectl set image deploy/web whoami=traefik/whoami:v1.11.0
kubectl get rs                         # new RS scaled up, old RS scaled to 0
kubectl rollout history deploy web
kubectl rollout undo deploy web
kubectl get rs                         # old RS reused, back to 5
```

**Point out:** Zero downtime. Pods are replaced a few at a time. Old RS is kept around so rollback is instant.

---

## 3. Service (~8 min)

**Say:** Pod IPs change every time a pod is recreated. A Service gives a stable IP and DNS name, and load-balances to whichever pods match its label selector.

```bash
cat 03-service.yaml
kubectl apply -f 03-service.yaml
kubectl get svc
kubectl describe svc web               # Endpoints: = the IPs of pods with app=web
kubectl get pods -o wide               # compare IPs; the unlabeled pod from step 2 is NOT in the list
```

**Inside the cluster (ClusterIP + DNS):**
```bash
kubectl run tmp --rm -it --image=busybox:1.36 -- sh
  wget -qO- http://web                 # repeat a few times: Hostname changes = load balancing
  exit
```

**From the laptop (NodePort):**
```bash
curl localhost:30090                   # repeat: different pod each time
```

**Service with no pods:**
```bash
kubectl scale deploy web --replicas=0
kubectl describe svc web               # Endpoints: <empty>
curl -m 3 localhost:30090              # fails
kubectl scale deploy web --replicas=3
```

**Point out:** A Service is just a label selector + stable address. Mention (no demo): `LoadBalancer` for cloud load balancers, `Ingress`/`Gateway` for HTTP routing by host/path.

---

## 4. ConfigMap & Secret (~7 min)

**Say:** Don't bake config into images. ConfigMap = non-sensitive config, Secret = sensitive values. Pods consume them as env vars or as files.

```bash
cat 04-config.yaml
kubectl apply -f 04-config.yaml
kubectl exec config-demo -- env | grep -E 'APP_|DB_'     # way 1: env vars
kubectl exec config-demo -- ls /etc/config              # way 2: one file per key
kubectl exec config-demo -- cat /etc/config/APP_COLOR
```

**Secrets are NOT encrypted:**
```bash
kubectl get secret app-secret -o yaml                   # DB_PASSWORD: czNjcjN0
kubectl get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

**Point out:** base64 is encoding, not encryption. Anyone who can read Secrets can read the password. Real clusters protect them with RBAC, encryption at rest, or external secret managers (Vault, cloud KMS).

**Mention only (too slow to demo live):** after editing a ConfigMap, mounted files update in ~1–2 min, but env vars never change until the pod restarts (`kubectl rollout restart deploy/<name>`).

---

## 5. StatefulSet (~8 min)

**Say:** Deployment pods are cattle: random names, interchangeable, no own disk. Databases need pets: a stable name, a stable network identity, and their own disk that survives restarts. That's a StatefulSet.

```bash
cat 05-statefulset.yaml                # headless Service (clusterIP: None) + volumeClaimTemplates
kubectl apply -f 05-statefulset.yaml   # watch right pane: db-0, then db-1, then db-2 (in order)
kubectl get pvc                        # one disk per pod: data-db-0, data-db-1, data-db-2
```

**Data survives pod deletion:**
```bash
kubectl exec db-0 -- sh -c 'echo "hello from db-0" > /usr/share/nginx/html/index.html'
kubectl delete pod db-0                # comes back with the SAME name...
kubectl exec db-0 -- cat /usr/share/nginx/html/index.html   # ...and the SAME data
```

**Stable per-pod DNS:**
```bash
kubectl run tmp --rm -it --image=busybox:1.36 -- wget -qO- http://db-0.db
```

**Point out:** Compare with step 2, where a deleted pod came back with a new random name and nothing saved.

---

## 6. HPA — Horizontal Pod Autoscaler (~8 min, finale)

**Say:** The HPA watches CPU usage and adjusts replica count automatically. It needs metrics-server (installed in setup) and CPU `requests` on the pods, since usage is measured as a % of the request.

```bash
kubectl top nodes
kubectl top pods
kubectl scale deploy web --replicas=1
cat 06-hpa.yaml
kubectl apply -f 06-hpa.yaml
kubectl get hpa                        # wait until TARGETS shows "cpu: 0%/50%", not <unknown>
```

**Generate load, then watch it scale:**
```bash
kubectl run load --image=busybox:1.36 -- sh -c 'while true; do wget -qO- http://web >/dev/null; done'
kubectl get hpa web -w                 # ~40s: TARGETS jumps to several hundred %, REPLICAS 1 -> 4 -> 5
```

**Stop the load:**
```bash
kubectl delete pod load
```

**Point out:** Scale-up is fast. Scale-down waits ~5 min (stabilization window) so it doesn't flap; don't wait for it on stage. Without `resources.requests` the HPA shows `<unknown>` and does nothing.

---

## 7. Offensive Security finale (~12–15 min)

**Full runbook: [`security-demo/RUNBOOK-SECURITY.md`](security-demo/RUNBOOK-SECURITY.md)** — one attack chain, two attack surfaces, tested end-to-end:

1. **Stolen ServiceAccount token** — exec into the app pod, decode the JWT, talk to the API server with plain `curl`, and exfiltrate the DB password from `app-secret` (callback to step 4).
2. **Privileged pod → node escape** — the SA can `create pods`, so deploy a `privileged` + `hostPath` pod pinned to the control-plane node, steal `admin.conf`, and become cluster-admin.
3. **Fix it live** — delete the RoleBinding, label the namespace `pod-security.kubernetes.io/enforce=restricted`, patch `automountServiceAccountToken: false` — then re-run both attacks and watch them fail.

```bash
cd security-demo && ./reset.sh     # ~10s setup
```

---

## 8. Wrap-up (~3 min)

```bash
kubectl get all
```

Recap:
- **Node** runs **Pods**
- **Deployment** → **ReplicaSet** → Pods (stateless, self-healing, rolling updates)
- **StatefulSet** → Pods + own **PVC** each (stable name + data)
- **Service** finds pods by **label** → stable IP/DNS + load balancing
- **ConfigMap / Secret** → injected into pods as env vars or files
- **HPA** → changes a Deployment's replica count based on CPU

```bash
kind delete cluster --name k8s-demo
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `kubectl top` says metrics not available | wait ~1 min after setup |
| HPA TARGETS `<unknown>` | wait ~30s; check `kubectl top pods` works |
| Pod stuck `ErrImagePull` | image not preloaded; use exact tags from `setup.sh` |
| `localhost:30090` refused | cluster not created from `kind-config.yaml`; rerun `./setup.sh` |
| Port 30090 already allocated | another kind cluster uses it; change the port in `kind-config.yaml` + `03-service.yaml` |
