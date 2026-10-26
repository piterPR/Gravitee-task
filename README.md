# Gravitee APIM on local Kubernetes: `GET /ping` → `pong`

Minimal Gravitee API Management (Community Edition) on a local `kind` cluster.
`https://localhost:8443/ping` returns `pong` through the gateway.

## Prerequisites

| Tool | Tested with | Notes |
|---|---|---|
| Docker | Docker Desktop, 8 GB RAM | 4 CPU / 6 GB is enough, ~2 GB of images are pulled once |
| kind | 0.33 | |
| kubectl | 1.32 | |
| Helm | 4.3 (3.8+ should work, OCI charts needed) | |
| make, curl, openssl | system versions | |

## Run

```sh
make up     # cluster + everything, safe to re-run (idempotent)
make test   # /ping with CA verification, /ping with -k (both must give 200 + "pong"), /not-working (must give 404)
make down   # deletes the cluster

make up-analytics     # optional: same as `make up` plus Elasticsearch analytics (~1.5 GB RAM more)
make test-analytics   # prints what is stored in Elasticsearch (run `make test` first for traffic)
```

Manual check: `curl --cacert <(kubectl --context kind-gravitee -n cert-manager get secret gravitee-ca -o jsonpath='{.data.ca\.crt}' | base64 -d) https://localhost:8443/ping`

## Verify it yourself

```sh
k() { kubectl --context kind-gravitee "$@"; }

kind get clusters; k get nodes                      # 1 control-plane + 2 workers, Ready
k -n gravitee get pods -o wide                      # gateway x2, pong x2 on different nodes, GKO; all Ready
k -n gravitee get apiv4definition,configmap ping    # API as code, stored by GKO in ConfigMap "ping"
k -n gravitee get certificate                       # gateway-tls READY=True
k -n gravitee get pdb                               # PodDisruptionBudgets for gateway and pong

make test                                            # shows each curl -i and its response, fails on mismatch
curl -k -i https://localhost:8443/ping               # -k skips CA check; plain HTTP must NOT work:
curl -i http://localhost:8443/ping                   #   (fails: the port speaks TLS only)
curl -k -i https://localhost:8443/not-working        # 404: only /ping is exposed

# TLS certificate: issuer and validity
openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -issuer -dates

# Metrics (from inside the cluster; the password is random per cluster)
PW=$(k -n gravitee get secret gateway-metrics -o jsonpath='{.data.password}' | base64 -d)
k -n gravitee exec deploy/apim-gateway -- curl -s -u admin:$PW apim-gateway-metrics:18082/_node/metrics/prometheus | grep http_server_requests_total
k -n gravitee exec deploy/apim-gateway -- curl -s -o /dev/null -w '%{http_code}\n' apim-gateway-metrics:18082/_node/metrics/prometheus   # 401 without auth

# Resilience: take one worker out, /ping must keep answering
k drain gravitee-worker --ignore-daemonsets --delete-emptydir-data; make test; k uncordon gravitee-worker

# Idempotency: a second run changes nothing
make up && make test

# Security: Pod Security "restricted" is enforced, so a privileged pod is rejected
k -n gravitee run bad --image=busybox --privileged   # Error ... violates PodSecurity "restricted"
```

## Architecture

```
 curl ──HTTPS :8443──▶ kind node :30443 (NodePort)
                              │
                    ┌─────────▼──────────┐   reads API config    ┌─────────────┐
                    │ Gravitee gateway x2 │◀── ConfigMap "ping" ──│ GKO operator │◀─ ApiV4Definition (YAML)
                    │ (DB-less, TLS)      │                       └─────────────┘
                    └─────────┬──────────┘
                              │ http
                       ┌──────▼──────┐        cert-manager ─▶ Secret gateway-tls (renewed automatically)
                       │ pong x2     │
                       └─────────────┘        :18082 /_node/metrics/prometheus (ClusterIP, basic auth)
```

Cluster: 1 control-plane + 2 workers, so replicas actually spread over nodes.
Everything lives in namespace `gravitee` (Pod Security `restricted`), cert-manager in its own.

## Choices and alternatives

| Choice | Why | Alternative considered |
|---|---|---|
| **DB-less gateway + GKO** | API config is plain YAML (`manifests/30-api.yaml`). No MongoDB, no Management API, no Elasticsearch. | Classic mode (MongoDB + Management API + REST bootstrap script): more parts, config is not declarative. Cost of mine: no Console / Portal. |
| **kind** | Runs in Docker, same on macOS and Linux, multi-node. | minikube, k3d: equivalent. |
| **Makefile + helm + kubectl** | No extra tooling, versions pinned at the top of the Makefile. | Helmfile / Terraform / Argo CD: better at scale, overkill here. |
| **Gateway terminates TLS** | One component less. cert-manager renews the cert, the gateway reloads it without restart. | ingress-nginx is retired; Gateway API / a LoadBalancer is the production route. |
| **Local CA via cert-manager** | Let's Encrypt cannot validate `localhost`. In production only the `issuerRef` of the Certificate changes (ACME issuer). | Self-signed cert by hand: no renewal. |
| **`hashicorp/http-echo` as backend** | No image to build, tiny, non-root. | Own image: only worth it for real logic. |

## Assumptions

- "Production-grade" means the configuration, not the local machine: pinned versions, non-root, `seccomp`, dropped capabilities, requests/limits, probes, 2 replicas, PodDisruptionBudgets, topology spread, namespace-scoped operator, random secrets generated at deploy time.
- `/ping` is keyless (no authentication plan).
- **Elasticsearch / analytics are optional and off by default** (`make up-analytics` turns them on, see below).
- The TLS key is RSA 2048 in PKCS8: the gateway's PEM loader rejected ECDSA and the default SEC1 format.

## Optional: analytics (Elasticsearch)

`make up-analytics` adds a single-node Elasticsearch (`manifests/optional/elasticsearch.yaml`, 8.17.4, password in a
generated Secret, 2 Gi volume) and switches on the gateway's Elasticsearch reporter (`helm/apim.analytics.values.yaml`).
`make test-analytics` prints what is stored in the `gravitee-v4-metrics-*` indices: a summary (requests per API, URI
and status, gateway latency p50/p95/p99, backend latency, bytes) and the latest 5 requests. It fails if the index is empty.

- Without it nothing is stored: the API keeps `analytics.enabled: true`, which is free when no reporter is running.
- There is **no UI** for this data: Gravitee shows analytics in the Console through the Management API, and neither
  exists in DB-less mode. Query Elasticsearch directly, e.g.
  `kubectl -n gravitee exec sts/elasticsearch -- curl -s -u elastic:<password> 'localhost:9200/gravitee-v4-metrics-*/_search?size=1'`
  (password: Secret `elasticsearch`).
- A plain `make up` afterwards turns the reporter off again but leaves Elasticsearch running; `make down` removes everything.
- Local-demo shortcuts, not production: one node and no replicas, plain HTTP inside the cluster, the built-in `elastic`
  superuser (use a dedicated role), the chart stores the password in the gateway ConfigMap, the root filesystem is writable.

## Metrics

Gateway Prometheus endpoint: `:18082/_node/metrics/prometheus` through the internal Service `apim-gateway-metrics`
(basic auth, user `admin`, random password in Secret `gateway-metrics`).

```sh
kubectl --context kind-gravitee -n gravitee get secret gateway-metrics -o jsonpath='{.data.password}' | base64 -d
```

What I would watch: request rate and **5xx ratio** per API, **p95/p99 latency** (`http_server_*`, upstream latency),
active connections, JVM heap / GC, pod restarts and readiness, **certificate expiry** (cert-manager metrics),
and GKO reconcile errors (it reports a `Reconciler error` when an API definition is invalid).

## Missing before production

- **NetworkPolicies** (default deny; allow only client → gateway → backend, Prometheus → metrics). Not done: kind's CNI support must be checked first.
- **Gateway hardening**: `readOnlyRootFilesystem` with explicit writable volumes (not verified with this chart).
- **Metrics password**: the chart writes it into the ConfigMap and the probe spec, so it is not secret from anyone who can read pods. Better: no auth + NetworkPolicy, or a dedicated metrics listener with mTLS.
- **Real PKI**: ACME issuer, a real DNS name, ideally a LoadBalancer / Gateway API instead of a NodePort.
- **Monitoring and alerting**: Prometheus + ServiceMonitor, dashboards, alerts on the signals above, log shipping.
- **Authentication on the API** (keyless plan today), rate limiting (needs Redis), distributed gateway sync.
- **Image supply chain**: pin by digest, mirror to a private registry, scan.
- **Delivery**: CI (lint, `kubeconform`, e2e on kind) and GitOps instead of `make`; backups are not needed while DB-less (Git is the source of truth).
- **Zero-downtime eviction**: during a node drain I saw one failed request before `make test` retried successfully (traffic still hits a terminating pod). Needs a `preStop` delay on the gateway and a real load balancer with health checks. Evicted pods are also not rebalanced after `uncordon` (descheduler).
- GKO restarts once on first start (webhook certificate race); harmless, not investigated.
