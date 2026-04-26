#!/usr/bin/env bash
# teardown-local.sh — Remove the local test ArgoCD installation from kind.
# Does NOT touch Istio, Knative, or the hello-sourceless workload itself.

set -euo pipefail

echo "==> Deleting all ArgoCD Applications"
kubectl delete applications --all -n argocd 2>/dev/null || true

echo "==> Deleting ArgoCD AppProjects (non-default)"
kubectl delete appproject infrastructure applications -n argocd 2>/dev/null || true

echo "==> Uninstalling ArgoCD Helm release"
helm uninstall argocd -n argocd 2>/dev/null || true

echo "==> Deleting argocd namespace"
kubectl delete namespace argocd --timeout=60s 2>/dev/null || true

echo "==> Stopping git daemon"
if [[ -f /tmp/git-daemon-test.pid ]]; then
  kill "$(cat /tmp/git-daemon-test.pid)" 2>/dev/null && echo "  git daemon stopped" || echo "  already stopped"
  rm -f /tmp/git-daemon-test.pid
fi
pkill -f "git daemon" 2>/dev/null || true

echo "==> Removing git-daemon-export-ok"
rm -f "$(cd "$(dirname "$0")/.." && pwd)/git-daemon-export-ok"

echo ""
echo "✓ Teardown complete. kind cluster, Istio, and Knative are untouched."
