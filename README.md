
# Self Service with Kyverno

This project showcases self-service namespace creation in Kubernetes using Kyverno.
When a user creates a namespace, Kyverno automatically generates an admin RoleBinding that grants the creator full administrative privileges within their own namespace — enabling isolated, self-managed environments for each tenant.

This model is similar to OpenShift Projects, where users can self-manage their own isolated workspaces.
The key difference is that in this setup, users can still see other namespaces in the cluster, but they cannot view or interact with any resources inside those namespaces unless they own them.


The setup builds a local Kind cluster that includes:

* Kyverno and Policy Reporter
* Cert-Manager with self-signed CA
* Ingress-NGINX
* External Secrets, Reloader, and OLM
* Prometheus stack configured with tenant tolerations
* Local pull-through registry caches for DockerHub, Quay, GHCR, and MCR

After setup, each user (like `david` and `sarah`) can create namespaces, trigger policies, and deploy apps — demonstrating automated RBAC, security policies, and isolation in action.

---

## 🧭 Getting Started

Run the following from the repo root:

```bash
./setup.sh
./test-setup.sh
```

Once complete, open **Headlamp** to explore the cluster.
You can switch between user contexts to see:

* Each user’s namespaces and workloads
* Kyverno-generated RoleBindings for namespace creators
* Active policies and compliance results visible in Policy Reporter

---

## 🧠 Summary

* **Self-service onboarding:** Users can create their own namespaces securely.
* **Automatic RBAC:** Kyverno grants admin access only to the creator.
* **Policy observability:** View enforcement and audit results live.
* **Local reproducibility:** Everything runs locally on Kind with minimal dependencies.

This environment demonstrates a practical pattern for **multi-tenant self-service clusters** with **automated RBAC and policy enforcement** — all driven by Kyverno.
