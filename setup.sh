#!/usr/bin/env bash
# Run BEFORE the talk (also works as a full reset).
# Recreates the cluster, preloads images (no pulls on venue wifi), installs metrics-server for HPA.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=k8s-demo
IMAGES=(nginx:1.27 busybox:1.36 traefik/whoami:v1.10.3 traefik/whoami:v1.11.0 curlimages/curl:8.11.1)

kind delete cluster --name "$CLUSTER"
kind create cluster --config kind-config.yaml

# save single-platform archives: `kind load docker-image` breaks on multi-arch images with Docker's containerd store
PLATFORM="linux/$(docker version --format '{{.Server.Arch}}')"
for img in "${IMAGES[@]}"; do
  docker pull --platform "$PLATFORM" "$img"
  docker save --platform "$PLATFORM" "$img" -o /tmp/kind-img.tar
  kind load image-archive /tmp/kind-img.tar --name "$CLUSTER"
done
rm -f /tmp/kind-img.tar

# metrics-server: kind kubelets use self-signed certs, hence --kubelet-insecure-tls
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment metrics-server

echo "Ready. Give metrics-server ~1 min, then 'kubectl top nodes' should work."
