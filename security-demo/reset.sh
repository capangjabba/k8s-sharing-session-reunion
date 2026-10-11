#!/usr/bin/env bash
# Reset the offensive-security demo on the CURRENT kind cluster.
# Run this before the talk, or any time you want a clean re-run.
#
# NOTE: 01-app.yaml uses curlimages/curl:8.11.1. For the k8s-demo cluster,
# add it to IMAGES in ../setup.sh (already done). On any other cluster the
# pod will just pull it from Docker Hub.
set -euo pipefail
cd "$(dirname "$0")"

# The main demo's web Deployment (whoami) gets replaced by our "compromised" one
kubectl delete deploy/web --ignore-not-found
kubectl delete pod/backup-tool --ignore-not-found --wait=false

# The vulnerable app + the over-granted RBAC
kubectl apply -f 01-app.yaml -f 02-rbac.yaml

# The loot for attack 1 (same secret as step 4 of the main demo)
kubectl delete secret app-secret --ignore-not-found
kubectl create secret generic app-secret \
  --from-literal=DB_USER=admin --from-literal=DB_PASSWORD=s3cr3t

kubectl rollout status deploy/web

# Remove any PodSecurity label left over from a previous run
if kubectl get ns default --show-labels | grep -q pod-security.kubernetes.io/enforce; then
  kubectl label --overwrite ns default pod-security.kubernetes.io/enforce-
fi

echo
echo "Ready. Start with:"
echo "  kubectl exec -it deploy/web -c app -- sh"
