#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env) =====
CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"
CTX_NAME="kind-${CLUSTER_NAME}"
USER_ORG="${USER_ORG:-devs}"
USERS=("david" "sarah")
OUT_DIR="${OUT_DIR:-create-cluster-output}"

say(){ printf '==> %s\n' "$*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

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
}

ensure_outdir(){
  mkdir -p "$OUT_DIR"
}

ensure_kind_cluster(){
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    say "Creating kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --name "${CLUSTER_NAME}"
  else
    say "Kind cluster '${CLUSTER_NAME}' already exists; skipping create."
  fi

  kubectl config get-contexts -o name | grep -qx "${CTX_NAME}" || \
    die "expected kube context '${CTX_NAME}' not found"
  kubectl config use-context "${CTX_NAME}" >/dev/null
}

install_kyverno() {
  say "Installing Kyverno via Helm..."
  helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  helm upgrade --install kyverno kyverno/kyverno \
    -n kyverno --create-namespace \
    --set config.enablePolicyException=true \
    --atomic >/dev/null

  # Give Kyverno controllers full admin (dev-only, very permissive)
  cat <<'EOF' | kubectl apply -f -
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
  helm upgrade --install kyverno-policies kyverno/kyverno-policies -n kyverno --create-namespace
}

apply_base_kyverno_policies() {
  say "Applying base Kyverno policies"
  kubectl apply -f ./policies.yaml
}

apply_namespace_owner_policy(){
  say "Applying Kyverno ClusterPolicy: namespace creator becomes admin of that namespace"
  cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: namespace-owner-admin
spec:
  background: false
  rules:
    - name: bind-creator-as-admin
      match:
        any:
          - resources:
              kinds:
                - Namespace
              operations:
                - CREATE
      generate:
        apiVersion: rbac.authorization.k8s.io/v1
        kind: RoleBinding
        name: ns-owner-admin
        namespace: "{{ request.object.metadata.name }}"
        synchronize: true
        data:
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: admin
          subjects:
            - kind: User
              name: "{{ request.userInfo.username }}"
EOF
}

create_namespace_rbac_for_users(){
  say "Creating ClusterRole to allow users to create/list/view namespaces"
  cat <<'EOF' | kubectl apply -f -
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
    say "Binding ClusterRole 'namespace-manager' to user '${u}'"
    kubectl apply -f - <<EOF
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
    say "Generating private key for user '$user' -> $key"
    openssl genrsa -out "$key" 2048 >/dev/null 2>&1
  else
    say "Key for '$user' exists; reusing."
  fi

  say "Generating CSR for '$user' -> $csr"
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

  say "Submitting CSR '${csr_name}'"
  kubectl apply -f "$csr_yaml" >/dev/null

  say "Approving CSR '${csr_name}'"
  kubectl certificate approve "${csr_name}" >/dev/null || true

  # Wait for the signed cert
  local tries=30 cert_b64=""
  while (( tries > 0 )); do
    cert_b64="$(kubectl get csr "${csr_name}" -o jsonpath='{.status.certificate}' || true)"
    [[ -n "$cert_b64" ]] && break
    sleep 1
    tries=$((tries-1))
  done
  [[ -z "$cert_b64" ]] && die "CSR '${csr_name}' has no issued certificate yet."

  printf '%s' "$cert_b64" | base64 -d > "$crt_file"
  say "Wrote client cert -> $crt_file"

  say "Adding kubeconfig user & context for '${user}'"
  kubectl config set-credentials "${user}" \
    --client-key="$key_file" \
    --client-certificate="$crt_file" \
    --embed-certs=true >/dev/null
  kubectl config set-context "${user}" --cluster "${CTX_NAME}" --user "${user}" >/dev/null
}

create_users(){
  for u in "${USERS[@]}"; do
    generate_key_and_csr "$u"
    submit_approve_and_write_cert "$u"
  done
}

main(){
  preflight
  ensure_outdir
  ensure_kind_cluster
  install_kyverno
  install_kyverno_pss
  apply_base_kyverno_policies
  apply_namespace_owner_policy
  create_namespace_rbac_for_users
  create_users
  say "Setup complete."
}

main "$@"
