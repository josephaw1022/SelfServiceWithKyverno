#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"
CTX_NAME="kind-${CLUSTER_NAME}"

say() { printf '==> %s\n' "$*"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FATAL: required binary '$1' not found in PATH" >&2
    exit 1
  }
}

preflight() {
  require_bin kind
  require_bin kubectl
  require_bin rm
}

delete_kind_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    say "Deleting kind cluster '${CLUSTER_NAME}'..."
    kind delete cluster --name "${CLUSTER_NAME}"
  else
    say "Cluster '${CLUSTER_NAME}' not found; skipping delete."
  fi
}

cleanup_kubeconfig() {
  say "Cleaning up kubeconfig entries for '${CTX_NAME}'..."
  
  kubectl config delete-context "${CTX_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-user "${CTX_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${CTX_NAME}" >/dev/null 2>&1 || true

  for u in david sarah jose; do
    kubectl config delete-context "${u}" >/dev/null 2>&1 || true
    kubectl config delete-user "${u}" >/dev/null 2>&1 || true
  done

  say "Kubeconfig cleanup complete."
}

delete_local_artifacts() {
  say "Removing generated key, cert, and CSR files..."
  rm -f ./*.key ./*.crt ./*.csr ./*-csr.yaml >/dev/null 2>&1 || true
  say "Local artifacts removed."
}

main() {
  preflight
  delete_kind_cluster
  cleanup_kubeconfig
  delete_local_artifacts
  say "Cleanup finished."
}

main "$@"
