#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"
CTX_NAME="kind-${CLUSTER_NAME}"

say(){ printf '==> %s\n' "$*"; }

require_bin(){
  command -v "$1" >/dev/null 2>&1 || {
    echo "FATAL: required binary '$1' not found in PATH" >&2
    exit 1
  }
}

preflight(){
  require_bin kind
  require_bin kubectl
  require_bin helm
}

ensure_cluster_exists(){
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    echo "FATAL: kind cluster '${CLUSTER_NAME}' not found" >&2
    exit 1
  fi
  kubectl config use-context "${CTX_NAME}" >/dev/null 2>&1 || true
}

remove_kyverno(){
  say "Uninstalling Kyverno Helm release (if exists)..."
  if helm status kyverno -n kyverno >/dev/null 2>&1; then
    helm uninstall kyverno -n kyverno >/dev/null 2>&1 || true
  else
    say "No Kyverno release found."
  fi

  say "Deleting Kyverno namespace..."
  kubectl delete ns kyverno --ignore-not-found >/dev/null 2>&1 || true

  say "Deleting Kyverno CRDs..."
  kubectl get crds -o name | grep 'kyverno' | xargs -r kubectl delete >/dev/null 2>&1 || true

  say "Deleting Kyverno ClusterRoles and ClusterRoleBindings..."
  kubectl get clusterrole,clusterrolebinding -o name | grep 'kyverno' | xargs -r kubectl delete >/dev/null 2>&1 || true

  say "Deleting Kyverno ClusterPolicy objects..."
  kubectl get clusterpolicy -o name 2>/dev/null | xargs -r kubectl delete >/dev/null 2>&1 || true
}

main(){
  preflight
  ensure_cluster_exists
  remove_kyverno
  say "Kyverno cleanup complete."
}

main "$@"
