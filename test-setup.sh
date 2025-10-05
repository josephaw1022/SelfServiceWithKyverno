#!/usr/bin/env bash
set -euo pipefail

USERS=("david" "sarah")
WAIT_SECS_ROLEBINDING="${WAIT_SECS_ROLEBINDING:-120}"  # total seconds to wait for RB
WAIT_SECS_ADMIN="${WAIT_SECS_ADMIN:-120}"              # total seconds to wait for admin rights
SLEEP_SECS=2

say(){ printf '==> %s\n' "$*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

require_bin(){
  command -v "$1" >/dev/null 2>&1 || die "required binary '$1' not found in PATH"
}

wait_for_rolebinding(){
  local ns="$1"
  local waited=0
  say "Waiting for Kyverno to generate RoleBinding 'ns-owner-admin' in '${ns}'..."
  until kubectl -n "${ns}" get rolebinding ns-owner-admin >/dev/null 2>&1; do
    sleep "${SLEEP_SECS}"
    waited=$((waited+SLEEP_SECS))
    if (( waited >= WAIT_SECS_ROLEBINDING )); then
      die "RoleBinding 'ns-owner-admin' not found in '${ns}' after ${WAIT_SECS_ROLEBINDING}s"
    fi
  done
  say "✅ RoleBinding 'ns-owner-admin' found in '${ns}'"
}


wait_for_admin(){
  local ctx="$1" ns="$2"
  local waited=0
  say "Waiting for '${ctx}' to have admin rights in '${ns}'..."

  while true; do
    # Read the generated RoleBinding safely (script is set -euo pipefail)
    local rb_kind rb_name subjects
    rb_kind="$(kubectl -n "${ns}" get rolebinding ns-owner-admin -o jsonpath='{.roleRef.kind}' 2>/dev/null || true)"
    rb_name="$(kubectl -n "${ns}" get rolebinding ns-owner-admin -o jsonpath='{.roleRef.name}' 2>/dev/null || true)"
    subjects="$(kubectl -n "${ns}" get rolebinding ns-owner-admin -o jsonpath="{range .subjects[*]}{.kind}:{.name}{'\n'}{end}" 2>/dev/null || true)"

    # Consider admin "effective" when the RB exists, points to ClusterRole/admin,
    # and includes the exact user as a subject.
    if [[ "${rb_kind}" == "ClusterRole" && "${rb_name}" == "admin" ]] && \
       grep -qx "User:${ctx}" <<< "${subjects}"; then
      say "✅ '${ctx}' confirmed admin in '${ns}'"
      return 0
    fi

    sleep "${SLEEP_SECS}"
    waited=$((waited+SLEEP_SECS))
    if (( waited >= WAIT_SECS_ADMIN )); then
      die "'${ctx}' did not gain admin in '${ns}' after ${WAIT_SECS_ADMIN}s"
    fi
  done
}


deploy_nginx(){
  local ctx="$1" ns="$2"
  say "Deploying nginx as '${ctx}' into '${ns}'..."
  kubectl --context="${ctx}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: ${ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
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
  name: nginx
  namespace: ${ns}
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF

  say "Waiting for nginx Deployment to become Available in '${ns}'..."
  kubectl --context="${ctx}" -n "${ns}" rollout status deploy/nginx --timeout=120s
  say "✅ nginx up in '${ns}'"
  kubectl --context="${ctx}" -n "${ns}" get deploy/nginx svc/nginx -o wide
}

main(){
  require_bin kubectl

  for u in "${USERS[@]}"; do
    ns="${u}-created-ns-test-$(date +%s)"
    say "Creating namespace '${ns}' as ${u}"
    kubectl --context="${u}" create ns "${ns}"

    # Hard block until RB is generated and admin is effective
    wait_for_rolebinding "${ns}"
    wait_for_admin "${u}" "${ns}"

    # Now deploy workload as that user
    deploy_nginx "${u}" "${ns}"
    echo
  done

  say "Policy test complete."
}

main "$@"
