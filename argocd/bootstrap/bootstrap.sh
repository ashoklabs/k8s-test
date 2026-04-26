#!/usr/bin/env bash
# bootstrap.sh — one-time cluster bootstrap for ArgoCD + SOPS
# Run this once after creating your kind (or real) cluster.
# Everything after this is managed by ArgoCD (GitOps).
#
# Prerequisites: kubectl, helm, age-keygen, sops, kubectl context pointing at your cluster.

set -euo pipefail

REPO_URL="${1:-https://github.com/YOUR_ORG/K8s-test.git}"
ARGOCD_VERSION="7.8.26"

echo "==> [1/5] Create argocd namespace"
kubectl apply -f argocd/bootstrap/argocd-namespace.yaml

echo "==> [2/5] Create SOPS AGE secret in argocd namespace"
if [[ ! -f age.agekey ]]; then
  echo "  Generating new AGE key pair → age.agekey (keep this safe, never commit it)"
  age-keygen -o age.agekey
fi
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.agekey=age.agekey \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [3/5] Install ArgoCD via Helm"
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_VERSION}" \
  -f argocd/bootstrap/argocd-values.yaml \
  --wait

echo "==> [4/5] Apply ArgoCD AppProjects"
kubectl apply -f argocd/projects/

echo "==> [5/5] Apply root App-of-Apps (hands control to ArgoCD)"
# Update the repoURL in root-app.yaml first if needed
sed "s|https://github.com/YOUR_ORG/K8s-test.git|${REPO_URL}|g" \
  argocd/apps/root-app.yaml | kubectl apply -f -

echo ""
echo "✓ Bootstrap complete. ArgoCD is now managing the cluster."
echo "  Access the UI:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Admin password: kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "                    -o jsonpath='{.data.password}' | base64 -d"
