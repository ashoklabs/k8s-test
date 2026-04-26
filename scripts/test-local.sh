#!/usr/bin/env bash
# test-local.sh — Full local GitOps test using kind cluster + git daemon.
#
# What this does:
#   1. Commits any uncommitted changes
#   2. Starts a git daemon on the host (port 9418) to serve this repo
#   3. Creates the sops-age secret in the argocd namespace
#   4. Installs ArgoCD with the ksops CMP sidecar (via Helm)
#   5. Applies AppProjects
#   6. Applies all ArgoCD Applications pointing at git://host.docker.internal:9418/K8s-test
#   7. Watches sync status
#
# Usage:
#   ./scripts/test-local.sh
#
# Prerequisites:
#   - kind cluster running (kubectl context = kind-kind)
#   - age.agekey present in repo root
#   - helm, kubectl, sops, age installed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"
GIT_DAEMON_PORT=9418
GIT_BASE_DIR="$(dirname "$REPO_ROOT")"
# ArgoCD uses this URL to clone the repo from inside the kind cluster
LOCAL_GIT_URL="git://host.docker.internal:${GIT_DAEMON_PORT}/${REPO_NAME}"
ARGOCD_VERSION="7.8.26"
TMPDIR_ARGOCD="$(mktemp -d)"

cd "$REPO_ROOT"

###############################################################################
echo ""
echo "══════════════════════════════════════════════════════"
echo " Local GitOps Test — kind + git daemon + ArgoCD"
echo "══════════════════════════════════════════════════════"
echo " Repo root  : $REPO_ROOT"
echo " Git URL    : $LOCAL_GIT_URL"
echo " Temp dir   : $TMPDIR_ARGOCD"
echo "══════════════════════════════════════════════════════"
echo ""

###############################################################################
echo "==> [1/7] Commit any uncommitted changes"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -m "chore: local test commit [skip ci]"
  echo "  Committed."
else
  echo "  Nothing to commit."
fi

###############################################################################
echo ""
echo "==> [2/7] Start git daemon (port ${GIT_DAEMON_PORT})"

# Kill any existing git daemon on this port
pkill -f "git daemon.*${GIT_DAEMON_PORT}" 2>/dev/null || true
sleep 1

# Touch export-ok so git daemon serves this repo
touch "${REPO_ROOT}/git-daemon-export-ok"

git daemon \
  --reuseaddr \
  --base-path="${GIT_BASE_DIR}" \
  --export-all \
  --port="${GIT_DAEMON_PORT}" \
  --verbose \
  "${REPO_ROOT}" &
GIT_DAEMON_PID=$!
echo "  git daemon PID: $GIT_DAEMON_PID (listening on port ${GIT_DAEMON_PORT})"
sleep 2

# Quick connectivity check from host
if git ls-remote "${LOCAL_GIT_URL//host.docker.internal/localhost}" HEAD &>/dev/null; then
  echo "  ✓ git daemon is serving the repo"
else
  echo "  ✗ git daemon health check failed — check firewall or port conflict"
  exit 1
fi

###############################################################################
echo ""
echo "==> [3/7] Create argocd namespace + sops-age secret"
kubectl apply -f argocd/bootstrap/argocd-namespace.yaml

if [[ ! -f age.agekey ]]; then
  echo "  ERROR: age.agekey not found. Run: age-keygen -o age.agekey"
  exit 1
fi

kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.agekey=age.agekey \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ sops-age secret applied"

###############################################################################
echo ""
echo "==> [4/7] Install ArgoCD via Helm"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_VERSION}" \
  -f argocd/bootstrap/argocd-values.yaml \
  --wait --timeout 5m
echo "  ✓ ArgoCD installed"

###############################################################################
echo ""
echo "==> [5/7] Apply AppProjects"
# Patch repo URLs to local git daemon URL
cp -r argocd/projects/ "${TMPDIR_ARGOCD}/projects/"
find "${TMPDIR_ARGOCD}/projects" -name "*.yaml" -exec \
  sed -i '' "s|https://github.com/YOUR_ORG/K8s-test.git|${LOCAL_GIT_URL}|g" {} \;
kubectl apply -f "${TMPDIR_ARGOCD}/projects/"
echo "  ✓ AppProjects applied"

###############################################################################
echo ""
echo "==> [6/7] Apply ArgoCD Applications (local git URL)"
cp -r argocd/apps/ "${TMPDIR_ARGOCD}/apps/"
find "${TMPDIR_ARGOCD}/apps" -name "*.yaml" -exec \
  sed -i '' "s|https://github.com/YOUR_ORG/K8s-test.git|${LOCAL_GIT_URL}|g" {} \;

# Apply root-app (App-of-Apps) — it will auto-create all child apps from the apps/ folder
kubectl apply -f "${TMPDIR_ARGOCD}/apps/root-app.yaml"
echo "  ✓ root-app applied"
echo ""
echo "  Waiting 30s for ArgoCD to discover child apps..."
sleep 30

# Apply remaining child apps explicitly (in case root-app hasn't self-synced yet)
kubectl apply -f "${TMPDIR_ARGOCD}/apps/"
echo "  ✓ All Application manifests applied"

###############################################################################
echo ""
echo "==> [7/7] Sync hello-sourceless (focus test — ksops decryption)"
echo "  Triggering manual sync for hello-sourceless..."
kubectl -n argocd patch application hello-sourceless \
  --type merge -p '{"operation":{"initiatedBy":{"username":"test-local"},"sync":{"revision":"HEAD","prune":true}}}' \
  2>/dev/null || true

echo ""
echo "  Waiting up to 3 minutes for hello-sourceless to sync..."
for i in $(seq 1 36); do
  STATUS=$(kubectl get application hello-sourceless -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  HEALTH=$(kubectl get application hello-sourceless -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  echo "  [$(( i * 5 ))s] Sync: ${STATUS}  Health: ${HEALTH}"
  if [[ "$STATUS" == "Synced" ]]; then
    break
  fi
  sleep 5
done

###############################################################################
echo ""
echo "══════════════════════════════════════════════════════"
echo " Test Results"
echo "══════════════════════════════════════════════════════"
echo ""
echo "ArgoCD Applications:"
kubectl get applications -n argocd 2>/dev/null || echo "  (none yet)"

echo ""
echo "Secrets in istio-system (from SOPS decryption):"
kubectl get secrets -n istio-system | grep -E "hello-sourceless|egress-client" || \
  echo "  (none yet — may need to wait for sync)"

echo ""
echo "ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080"
echo "  Password: $(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo '<run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d>')"

echo ""
echo "To stop the git daemon: kill ${GIT_DAEMON_PID}"
echo "To clean up ArgoCD:     ./scripts/teardown-local.sh"
echo ""

# Store PID for teardown
echo "$GIT_DAEMON_PID" > /tmp/git-daemon-test.pid
echo "══════════════════════════════════════════════════════"
