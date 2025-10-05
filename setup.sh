#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"
CTX_NAME="kind-${CLUSTER_NAME}"
USER_ORG="${USER_ORG:-devs}"
USERS=("david" "sarah")
OUT_DIR="${OUT_DIR:-create-cluster-output}"
KIND_CONFIG="${KIND_CONFIG:-kind-nodes.yaml}"

say(){
  printf '==> %s\n' "$*"
}

die(){
  echo "FATAL: $*" >&2
  exit 1
}

require_bin(){
  command -v "$1" >/dev/null 2>&1 || die "required binary '$1' not found in PATH"
}

preflight(){
  require_bin kind
  require_bin kubectl
  require_bin helm
  require_bin openssl
  require_bin base64
  require_bin tr
  require_bin operator-sdk
}

ensure_outdir(){
  mkdir -p "$OUT_DIR"
}

ensure_kind_cluster(){
  [[ -f "$KIND_CONFIG" ]] || die "missing kind config: $KIND_CONFIG"
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    say "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}..."
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  else
    say "Kind cluster '${CLUSTER_NAME}' already exists; skipping create."
  fi
  kubectl config get-contexts -o name | grep -qx "${CTX_NAME}" || die "expected kube context '${CTX_NAME}' not found"
  kubectl config use-context "${CTX_NAME}" >/dev/null
}



install_prometheus_stack() {
  say "Installing kube-prometheus-stack into kube-system..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    -n kube-system \
    --version 77.13.0 \
    --atomic \
    --create-namespace \
    -f /dev/stdin <<EOF
tolerations:
  - key: "tenant"
    operator: "Equal"
    value: "david"
    effect: "NoSchedule"
  - key: "tenant"
    operator: "Equal"
    value: "sarah"
    effect: "NoSchedule"

prometheus:
  prometheusSpec:
    tolerations:
      - key: "tenant"
        operator: "Equal"
        value: "david"
        effect: "NoSchedule"
      - key: "tenant"
        operator: "Equal"
        value: "sarah"
        effect: "NoSchedule"

alertmanager:
  alertmanagerSpec:
    tolerations:
      - key: "tenant"
        operator: "Equal"
        value: "david"
        effect: "NoSchedule"
      - key: "tenant"
        operator: "Equal"
        value: "sarah"
        effect: "NoSchedule"
EOF
}


install_kyverno() {
  say "Installing Kyverno via Helm..."
  helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install kyverno kyverno/kyverno \
    -n kyverno \
    --create-namespace \
    --atomic \
    -f /dev/stdin <<EOF
features:
  policyExceptions:
    enabled: true
    namespace: "*"
EOF
  grant_kyverno_admin
}

grant_kyverno_admin() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno-controllers-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: kyverno-admission-controller
    namespace: kyverno
  - kind: ServiceAccount
    name: kyverno-background-controller
    namespace: kyverno
EOF
}


install_kyverno_pss() {
  helm upgrade --install kyverno-policies kyverno/kyverno-policies -n kyverno --create-namespace >/dev/null
}

apply_base_kyverno_policies(){
  [[ -f ./policies.yaml ]] || die "missing ./policies.yaml"
  say "Applying base Kyverno policies from ./policies.yaml"
  kubectl apply -f ./policies.yaml >/dev/null
}

create_namespace_rbac_for_users(){
  cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-manager
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get","list","watch","create"]
EOF
  for u in "${USERS[@]}"; do
    kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: namespace-manager-${u}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: namespace-manager
subjects:
  - kind: User
    name: ${u}
EOF
  done
}

generate_key_and_csr(){
  local user="$1"
  local key="${OUT_DIR}/${user}.key"
  local csr="${OUT_DIR}/${user}.csr"
  if [[ ! -f "$key" ]]; then
    openssl genrsa -out "$key" 2048 >/dev/null 2>&1
  fi
  openssl req -new -key "$key" -out "$csr" -subj "/CN=${user}/O=${USER_ORG}" >/dev/null 2>&1
}

submit_approve_and_write_cert(){
  local user="$1"
  local key_file="${OUT_DIR}/${user}.key"
  local csr="${OUT_DIR}/${user}.csr"
  local csr_name="${user}"
  local csr_yaml="${OUT_DIR}/${user}-csr.yaml"
  local crt_file="${OUT_DIR}/${user}.crt"
  kubectl delete csr "${csr_name}" --ignore-not-found >/dev/null 2>&1 || true
  local csr_b64
  csr_b64="$(base64 < "$csr" | tr -d '\n')"
  cat > "$csr_yaml" <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${csr_name}
spec:
  request: ${csr_b64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
EOF
  kubectl apply -f "$csr_yaml" >/dev/null
  kubectl certificate approve "${csr_name}" >/dev/null || true
  local tries=30 cert_b64=""
  while (( tries > 0 )); do
    cert_b64="$(kubectl get csr "${csr_name}" -o jsonpath='{.status.certificate}' || true)"
    [[ -n "$cert_b64" ]] && break
    sleep 1
    tries=$((tries-1))
  done
  [[ -z "$cert_b64" ]] && die "CSR '${csr_name}' has no issued certificate yet."
  printf '%s' "$cert_b64" | base64 -d > "$crt_file"
  kubectl config set-credentials "${user}" --client-key="$key_file" --client-certificate="$crt_file" --embed-certs=true >/dev/null
  kubectl config set-context "${user}" --cluster "${CTX_NAME}" --user "${user}" >/dev/null
}

create_users(){
  for u in "${USERS[@]}"; do
    generate_key_and_csr "$u"
    submit_approve_and_write_cert "$u"
  done
}


install_olm(){
  echo "Installing OLM..."
  operator-sdk olm install || true

}


install_kyverno_stack() {
  install_kyverno
  grant_kyverno_admin
  install_kyverno_pss
}


main(){
  preflight
  ensure_outdir
  ensure_kind_cluster
  install_prometheus_stack
  install_kyverno_stack
  apply_base_kyverno_policies
  create_namespace_rbac_for_users
  create_users
  install_olm
  say "Setup complete."
}

main "$@"
