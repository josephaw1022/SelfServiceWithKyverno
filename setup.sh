#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"
CTX_NAME="kind-${CLUSTER_NAME}"
USER_ORG="${USER_ORG:-devs}"
USERS=("david" "sarah")
OUT_DIR="${OUT_DIR:-create-cluster-output}"
KIND_CONFIG="${KIND_CONFIG:-kind-config.yaml}"
log(){
    local level="$1"
    shift
    local color_reset="\033[0m"
    local color
    case "$level" in
        INFO) color="\033[1;34m" ;;    # Blue
        WARN|WARNING) color="\033[1;33m" ;; # Yellow
        ERROR|FATAL) color="\033[1;31m" ;;  # Red
        *) color="\033[0m" ;;
    esac
    printf '%b[%s] %s: %s%b\n' "$color" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" "$color_reset"
}

say(){
    local color="\033[1;32m" # Green
    local color_reset="\033[0m"
    printf '%b==> %s%b\n' "$color" "$*" "$color_reset"
}

die(){
  echo "FATAL: $*" >&2
  exit 1
}

require_bin(){
  command -v "$1" >/dev/null 2>&1 || die "required binary '$1' not found in PATH"
}

preflight(){
  log "INFO" "Starting preflight checks"
  require_bin kind
  require_bin kubectl
  require_bin helm
  require_bin openssl
  require_bin base64
  require_bin tr
  require_bin operator-sdk
  log "INFO" "All required binaries found"
}

ensure_outdir(){
  log "INFO" "Ensuring output directory: $OUT_DIR"
  mkdir -p "$OUT_DIR"
  log "INFO" "Output directory ready"
}



ensure_local_kind_registry() {
  if [ "$(docker inspect -f '{{.State.Running}}' local-registry 2>/dev/null || true)" != "true" ]; then
    echo "creating local registry..."
    docker run -d --restart=always \
      --network kind \
      -p "127.0.0.1:5001:5000" \
      --name local-registry \
      registry:2
  else
    echo "local-registry already running"
  fi
}

setup_dockerhub_pullthrough_cache() {
  if [ "$(docker inspect -f '{{.State.Running}}' dockerhub-proxy-cache 2>/dev/null || true)" != "true" ]; then
    echo "creating dockerhub pull-through cache container..."

    echo -n "Docker Hub username (leave blank for anonymous): "
    read USERNAME
    echo -n "Docker Hub token/password (leave blank for anonymous): "
    stty -echo; read PASSWORD; stty echo; echo

    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
      docker run -d --restart=always \
        --network kind \
        -p "5000:5000" \
        --name dockerhub-proxy-cache \
        -e REGISTRY_PROXY_REMOTEURL="https://registry-1.docker.io" \
        -e REGISTRY_PROXY_USERNAME="$USERNAME" \
        -e REGISTRY_PROXY_PASSWORD="$PASSWORD" \
        registry:2
    else
      docker run -d --restart=always \
        --network kind \
        -p "5000:5000" \
        --name dockerhub-proxy-cache \
        -e REGISTRY_PROXY_REMOTEURL="https://registry-1.docker.io" \
        registry:2
    fi
  else
    echo "dockerhub-proxy-cache already running"
  fi
}

setup_quay_pullthrough_cache() {
  if [ "$(docker inspect -f '{{.State.Running}}' quay-proxy-cache 2>/dev/null || true)" != "true" ]; then
    echo "creating quay.io pull-through cache container..."
    docker run -d --restart=always \
      --network kind \
      -p "5002:5000" \
      --name quay-proxy-cache \
      -e REGISTRY_PROXY_REMOTEURL="https://quay.io" \
      registry:2
  else
    echo "quay-proxy-cache already running"
  fi
}

setup_ghcr_pullthrough_cache() {
  if [ "$(docker inspect -f '{{.State.Running}}' ghcr-proxy-cache 2>/dev/null || true)" != "true" ]; then
    echo "creating ghcr.io pull-through cache container..."
    docker run -d --restart=always \
      --network kind \
      -p "5003:5000" \
      --name ghcr-proxy-cache \
      -e REGISTRY_PROXY_REMOTEURL="https://ghcr.io" \
      registry:2
  else
    echo "ghcr-proxy-cache already running"
  fi
}

setup_mcr_pullthrough_cache() {
  if [ "$(docker inspect -f '{{.State.Running}}' mcr-proxy-cache 2>/dev/null || true)" != "true" ]; then
    echo "creating mcr.microsoft.com pull-through cache container..."
    docker run -d --restart=always \
      --network kind \
      -p "5004:5000" \
      --name mcr-proxy-cache \
      -e REGISTRY_PROXY_REMOTEURL="https://mcr.microsoft.com" \
      registry:2
  else
    echo "mcr-proxy-cache already running"
  fi
}

configure_kind_nodes_for_local_registry() {
  for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    echo "patching node $node"

    # local registry mirror
    docker exec "$node" mkdir -p /etc/containerd/certs.d/localhost:5001
    docker exec -i "$node" bash -c "cat > /etc/containerd/certs.d/localhost:5001/hosts.toml" <<EOF
[host."http://local-registry:5000"]
EOF

    # dockerhub mirror
    docker exec "$node" mkdir -p /etc/containerd/certs.d/docker.io
    docker exec -i "$node" bash -c "cat > /etc/containerd/certs.d/docker.io/hosts.toml" <<EOF
[host."http://dockerhub-proxy-cache:5000"]
EOF

    # quay mirror
    docker exec "$node" mkdir -p /etc/containerd/certs.d/quay.io
    docker exec -i "$node" bash -c "cat > /etc/containerd/certs.d/quay.io/hosts.toml" <<EOF
[host."http://quay-proxy-cache:5000"]
EOF

    # ghcr mirror
    docker exec "$node" mkdir -p /etc/containerd/certs.d/ghcr.io
    docker exec -i "$node" bash -c "cat > /etc/containerd/certs.d/ghcr.io/hosts.toml" <<EOF
[host."http://ghcr-proxy-cache:5000"]
EOF

    # mcr mirror
    docker exec "$node" mkdir -p /etc/containerd/certs.d/mcr.microsoft.com
    docker exec -i "$node" bash -c "cat > /etc/containerd/certs.d/mcr.microsoft.com/hosts.toml" <<EOF
[host."http://mcr-proxy-cache:5000"]
EOF

  done

  kubectl apply --context "$CTX_NAME" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5001"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}



ensure_kind_cluster(){
  log "INFO" "Ensuring kind cluster: $CLUSTER_NAME"
  [[ -f "$KIND_CONFIG" ]] || die "missing kind config: $KIND_CONFIG"
  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "INFO" "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
    say "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}..."
    kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
    log "INFO" "Kind cluster created successfully"
  else
    log "INFO" "Kind cluster '${CLUSTER_NAME}' already exists; skipping create"
    say "Kind cluster '${CLUSTER_NAME}' already exists; skipping create."
  fi
  kubectl config get-contexts -o name | grep -qx "${CTX_NAME}" || die "expected kube context '${CTX_NAME}' not found"
  kubectl config use-context "${CTX_NAME}" >/dev/null
  log "INFO" "Using kubectl context: $CTX_NAME"
}


install_cert_manager() {
  log "INFO" "Installing cert-manager via Helm"
  helm upgrade --install \
    cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version v1.18.2 \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true
  log "INFO" "cert-manager installation complete"
}


install_reloader() {
  log "INFO" "Installing reloader via Helm"
  helm repo add stakater https://stakater.github.io/stakater-charts
  helm repo update
  helm upgrade --install reloader stakater/reloader \
    --namespace reloader \
    --create-namespace \
    --atomic
  log "INFO" "reloader installation complete"
}

install_external_secrets() {
  log "INFO" "Installing external-secrets via Helm"
  helm repo add external-secrets https://charts.external-secrets.io
  helm repo update
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace \
    --version 0.20.1 \
    --set installCRDs=true \
    --atomic
  log "INFO" "external-secrets installation complete"
}



create_ca_via_cert_manager() {
  log "INFO" "Creating CA via cert-manager"
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: bootstrap-selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: root-ca
  secretName: root-ca
  issuerRef:
    name: bootstrap-selfsigned
    kind: ClusterIssuer
EOF

  log "INFO" "Waiting for root CA certificate to be ready"
  kubectl -n cert-manager wait certificate/root-ca --for=condition=Ready --timeout=180s

  log "INFO" "Creating root issuer"
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: root-issuer
spec:
  ca:
    secretName: root-ca
EOF

  kubectl delete clusterissuer bootstrap-selfsigned --ignore-not-found
  log "INFO" "CA setup complete"
}



install_ingress_nginx_nodeport() {
  log "INFO" "Installing ingress-nginx with NodePort service"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace -f - <<EOF
controller:
  service:
    type: NodePort
    nodePorts:
      http: 30080
      https: 30443
  publishService:
    enabled: true
  ingressClassResource:
    default: true
  config:
    ssl-redirect: "false"

defaultBackend:
  enabled: true
EOF
  log "INFO" "ingress-nginx installation complete"
}




install_prometheus_stack() {
  log "INFO" "Installing kube-prometheus-stack into kube-system"
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
  log "INFO" "kube-prometheus-stack installation complete"
}


apply_kyverno_config() {
  log "INFO" "Applying Kyverno configuration (namespace + ConfigMap)"
  kubectl apply -f kind-configuration-setup.yaml --wait
  log "INFO" "Kyverno configuration applied successfully"
}

install_kyverno() {
  log "INFO" "Installing Kyverno via Helm"
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
  log "INFO" "Kyverno installation complete"
  grant_kyverno_admin
}

grant_kyverno_admin() {
  log "INFO" "Granting cluster-admin permissions to Kyverno"
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
  log "INFO" "Kyverno admin permissions granted"
}


install_kyverno_pss() {
  log "INFO" "Installing Kyverno PSS policies"
  helm upgrade --install kyverno-policies kyverno/kyverno-policies -n kyverno --create-namespace >/dev/null
  log "INFO" "Kyverno PSS policies installation complete"
}

apply_base_kyverno_policies(){
  [[ -f ./policies.yaml ]] || die "missing ./policies.yaml"
  log "INFO" "Applying base Kyverno policies from ./policies.yaml"
  say "Applying base Kyverno policies from ./policies.yaml"
  kubectl apply -f ./policies.yaml >/dev/null
  log "INFO" "Base Kyverno policies applied successfully"

  [[ -f ./policies-auditing.yaml ]] || die "missing ./policies-auditing.yaml"
  log "INFO" "Applying auditing Kyverno policies from ./policies-auditing.yaml"
  say "Applying auditing Kyverno policies from ./policies-auditing.yaml"
  kubectl apply -f ./policies-auditing.yaml >/dev/null
  log "INFO" "Auditing Kyverno policies applied successfully"

}


install_policy_reporter() {
  log "INFO" "Installing policy-reporter via Helm"
  helm upgrade --install policy-reporter oci://ghcr.io/kyverno/charts/policy-reporter \
    --version 3.5.0 \
    --namespace kyverno-policy-reporter \
    --create-namespace \
    -f - <<EOF
ui:
  enabled: true
  service:
    port: 80
    targetPort: http
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: root-issuer
    hosts:
      - host: policy-reporter.localhost
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - policy-reporter.localhost
        secretName: policy-reporter-tls
kyvernoPlugin:
  enabled: true
EOF
  log "INFO" "policy-reporter installation complete"
}


create_namespace_rbac_for_users(){
  log "INFO" "Creating namespace RBAC for users: ${USERS[*]}"
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
    log "INFO" "Creating namespace manager binding for user: $u"
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
  log "INFO" "Namespace RBAC setup complete"
}

generate_key_and_csr(){
  local user="$1"
  local key="${OUT_DIR}/${user}.key"
  local csr="${OUT_DIR}/${user}.csr"
  log "INFO" "Generating key and CSR for user: $user"
  if [[ ! -f "$key" ]]; then
    openssl genrsa -out "$key" 2048 >/dev/null 2>&1
    log "INFO" "Generated private key for user: $user"
  else
    log "INFO" "Private key already exists for user: $user"
  fi
  openssl req -new -key "$key" -out "$csr" -subj "/CN=${user}/O=${USER_ORG}" >/dev/null 2>&1
  log "INFO" "Generated CSR for user: $user"
}

submit_approve_and_write_cert(){
  local user="$1"
  local key_file="${OUT_DIR}/${user}.key"
  local csr="${OUT_DIR}/${user}.csr"
  local csr_name="${user}"
  local csr_yaml="${OUT_DIR}/${user}-csr.yaml"
  local crt_file="${OUT_DIR}/${user}.crt"
  
  log "INFO" "Submitting CSR for user: $user"
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
  log "INFO" "CSR approved for user: $user"
  
  log "INFO" "Waiting for certificate to be issued for user: $user"
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
  log "INFO" "Certificate and kubectl context configured for user: $user"
}

create_users(){
  log "INFO" "Creating users: ${USERS[*]}"
  for u in "${USERS[@]}"; do
    generate_key_and_csr "$u"
    submit_approve_and_write_cert "$u"
  done
  log "INFO" "All users created successfully"
}


install_olm(){
  log "INFO" "Installing OLM (Operator Lifecycle Manager)"
  echo "Installing OLM..."
  operator-sdk olm install || true
  log "INFO" "OLM installation complete"
}


install_kyverno_stack() {
  log "INFO" "Installing Kyverno stack (Kyverno + admin permissions + PSS policies)"
  apply_kyverno_config
  install_kyverno
  grant_kyverno_admin
  install_kyverno_pss
  apply_base_kyverno_policies
  install_policy_reporter
  log "INFO" "Kyverno stack installation complete"
}


main(){
  log "INFO" "Starting cluster setup process"
  preflight
  ensure_outdir
  ensure_kind_cluster
  ensure_local_kind_registry
  setup_dockerhub_pullthrough_cache
  setup_quay_pullthrough_cache
  setup_ghcr_pullthrough_cache
  setup_mcr_pullthrough_cache
  configure_kind_nodes_for_local_registry
  install_cert_manager
  create_ca_via_cert_manager
  install_reloader
  install_external_secrets
  install_ingress_nginx_nodeport
  install_prometheus_stack
  install_kyverno_stack
  create_namespace_rbac_for_users
  create_users
  install_olm
  log "INFO" "Setup complete - all components installed and configured"
  say "Setup complete."
}

main "$@"
