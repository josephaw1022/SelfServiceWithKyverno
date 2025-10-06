#!/usr/bin/env bash
set -euo pipefail

USERS=("david" "sarah")
WAIT_SECS_ROLEBINDING="${WAIT_SECS_ROLEBINDING:-120}"
WAIT_SECS_ADMIN="${WAIT_SECS_ADMIN:-120}"
SLEEP_SECS=2
CHOICES=(nginx aspnet apache)

say() {
  printf '==> %s\n' "$*"
}

die() {
  echo "FATAL: $*" >&2
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "required binary '$1' not found"
}

wait_for_rolebinding() {
  local ns="$1"
  local waited=0

  say "Waiting for RoleBinding in '${ns}'..."
  until kubectl -n "${ns}" get rolebinding ns-owner-admin >/dev/null 2>&1; do
    sleep "${SLEEP_SECS}"
    waited=$((waited+SLEEP_SECS))
    if (( waited >= WAIT_SECS_ROLEBINDING )); then
      die "RoleBinding not found after ${WAIT_SECS_ROLEBINDING}s"
    fi
  done
  say "✅ RoleBinding found."
}

wait_for_admin() {
  local ctx="$1"
  local ns="$2"
  local waited=0

  say "Waiting for '${ctx}' to have admin in '${ns}'..."
  while true; do
    local rb_kind rb_name subjects
    rb_kind="$(kubectl -n "${ns}" get rolebinding ns-owner-admin -o jsonpath='{.roleRef.kind}' 2>/dev/null || true)"
    rb_name="$(kubectl -n "${ns}" get rolebinding ns-owner-admin -o jsonpath='{.roleRef.name}' 2>/dev/null || true)"
    subjects="$(kubectl -n "${ns}" get rolebinding ns-owner-admin -o jsonpath="{range .subjects[*]}{.kind}:{.name}{'\n'}{end}" 2>/dev/null || true)"

    if [[ "${rb_kind}" == "ClusterRole" && "${rb_name}" == "admin" ]] && grep -qx "User:${ctx}" <<< "${subjects}"; then
      say "✅ '${ctx}' confirmed admin"
      return 0
    fi

    sleep "${SLEEP_SECS}"
    waited=$((waited+SLEEP_SECS))
    if (( waited >= WAIT_SECS_ADMIN )); then
      die "'${ctx}' did not gain admin after ${WAIT_SECS_ADMIN}s"
    fi
  done
}


deploy_nginx() {
  local ctx="$1"
  local ns="$2"
  local user="$3"
  local timestamp="$4"
  local name="${user}-nginx-${timestamp}"

  kubectl --context="${ctx}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          volumeMounts:
            - mountPath: /var/cache/nginx
              name: nginx-cache
            - mountPath: /run
              name: nginx-run
      volumes:
        - name: nginx-cache
          emptyDir: {}
        - name: nginx-run
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  type: ClusterIP
  selector:
    app: ${name}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${ns}
  annotations:
    cert-manager.io/cluster-issuer: "root-issuer"
spec:

  rules:
    - host: ${name}.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${name}
                port:
                  number: 80
EOF

  kubectl --context="${ctx}" -n "${ns}" rollout status deploy/${name} --timeout=180s
  kubectl --context="${ctx}" -n "${ns}" get deploy/${name} svc/${name} ingress/${name} -o wide
}



deploy_aspnet() {
  local ctx="$1"
  local ns="$2"
  local user="$3"
  local timestamp="$4"
  local name="${user}-aspnet-${timestamp}"

  kubectl --context="${ctx}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: aspnetapp
          image: mcr.microsoft.com/dotnet/samples:aspnetapp-10.0
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  type: ClusterIP
  selector:
    app: ${name}
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${ns}
  annotations:
    cert-manager.io/cluster-issuer: "root-issuer"
spec:

  rules:
    - host: ${name}.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${name}
                port:
                  number: 80
EOF

  kubectl --context="${ctx}" -n "${ns}" rollout status deploy/${name} --timeout=180s
  kubectl --context="${ctx}" -n "${ns}" get deploy/${name} svc/${name} ingress/${name} -o wide
}



deploy_apache() {
  local ctx="$1"
  local ns="$2"
  local user="$3"
  local timestamp="$4"
  local name="${user}-apache-${timestamp}"

  kubectl --context="${ctx}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: httpd
          image: httpd:2.4
          command: ["/usr/local/bin/httpd-foreground"]
          args:
            - "-DFOREGROUND"
            - "-c"
            - "ServerName localhost"
            - "-c"
            - "PidFile /usr/local/apache2/logs/httpd.pid"
            - "-c"
            - "Listen 8080"
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: httpd-logs
              mountPath: /usr/local/apache2/logs
            - name: httpd-run
              mountPath: /usr/local/apache2/run
      volumes:
        - name: httpd-logs
          emptyDir: {}
        - name: httpd-run
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  type: ClusterIP
  selector:
    app: ${name}
  ports:
    - port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${ns}
  annotations:
    cert-manager.io/cluster-issuer: "root-issuer"
spec:
  rules:
    - host: ${name}.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${name}
                port:
                  number: 80
EOF

  kubectl --context="${ctx}" -n "${ns}" rollout status deploy/${name} --timeout=180s
  kubectl --context="${ctx}" -n "${ns}" get deploy/${name} svc/${name} ingress/${name} -o wide
}



deploy_random_app() {
  local ctx="$1"
  local ns="$2"
  local user="$3"
  local timestamp="$4"
  local pick="${CHOICES[RANDOM % ${#CHOICES[@]}]}"

  say "Random pick for '${user}': ${pick}"
  case "${pick}" in
    nginx)
      deploy_nginx "${ctx}" "${ns}" "${user}" "${timestamp}"
      ;;
    aspnet)
      deploy_aspnet "${ctx}" "${ns}" "${user}" "${timestamp}"
      ;;
    apache)
      deploy_apache "${ctx}" "${ns}" "${user}" "${timestamp}"
      ;;
    *)
      die "unknown app: ${pick}"
      ;;
  esac
}

create_ns_with_optional_skip_label() {
  local ctx="$1"
  local ns="$2"
  local use_label="$3"

  if [[ "${use_label}" == "true" ]]; then
    kubectl --context="${ctx}" create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    skip-network-policy: "true"
EOF
  else
    kubectl --context="${ctx}" create ns "${ns}"
  fi
}

main() {
  require_bin kubectl

  for u in "${USERS[@]}"; do
    local timestamp="$(date +%s)"
    ns="${u}-created-ns-test-${timestamp}"
    use_label=$([ $((RANDOM % 2)) -eq 0 ] && echo true || echo false)

    say "Creating namespace '${ns}' as ${u} (skip-network-policy=${use_label})"
    create_ns_with_optional_skip_label "${u}" "${ns}" "${use_label}"
    wait_for_rolebinding "${ns}"
    wait_for_admin "${u}" "${ns}"
    deploy_random_app "${u}" "${ns}" "${u}" "${timestamp}"
    echo
  done

  say "✅ Policy test complete."
}

main "$@"
