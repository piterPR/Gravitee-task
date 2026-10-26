CLUSTER       ?= gravitee
CTX           := kind-$(CLUSTER)
NS            := gravitee
GRAVITEE_REPO := https://helm.gravitee.io
CERT_MANAGER_CHART := oci://quay.io/jetstack/charts/cert-manager

# Pinned versions
CERT_MANAGER_VERSION := v1.21.2
GKO_VERSION          := 4.12.22
APIM_VERSION         := 4.12.23

KUBECTL := kubectl --context $(CTX)
HELM    := helm --kube-context $(CTX)

# Optional analytics: `make up-analytics` (= make up ANALYTICS=true) adds Elasticsearch
# and turns on the gateway's Elasticsearch reporter.
ANALYTICS ?= false
APIM_EXTRA := $(if $(filter true,$(ANALYTICS)),-f helm/apim.analytics.values.yaml \
	--set es.security.password=$$($(KUBECTL) -n $(NS) get secret elasticsearch -o jsonpath='{.data.password}' | base64 -d))

.PHONY: up up-analytics down test test-analytics cluster elasticsearch
up: cluster ## Build everything (idempotent)
	$(HELM) upgrade --install cert-manager $(CERT_MANAGER_CHART) --version $(CERT_MANAGER_VERSION) \
		-n cert-manager --create-namespace -f helm/cert-manager.values.yaml --wait
	$(KUBECTL) apply -f manifests/00-namespace.yaml
	$(KUBECTL) apply -f manifests/10-pki.yaml
	$(KUBECTL) -n $(NS) wait --for=condition=Ready certificate/gateway-tls --timeout=120s
	$(HELM) upgrade --install gko gko --repo $(GRAVITEE_REPO) --version $(GKO_VERSION) \
		-n $(NS) -f helm/gko.values.yaml --wait
	$(KUBECTL) apply -f manifests/20-backend.yaml
	@# GKO restarts once on first start (it registers its CRDs first), so its admission
	@# webhook can refuse connections for a few seconds after helm reports Ready: retry.
	@i=0; until $(KUBECTL) apply -f manifests/30-api.yaml; do \
		i=$$((i+1)); [ $$i -lt 20 ] || { echo "GKO webhook not reachable after 60s" >&2; exit 1; }; \
		echo "waiting for GKO webhook..."; sleep 3; \
	done
	$(KUBECTL) -n $(NS) get secret gateway-metrics >/dev/null 2>&1 || \
		$(KUBECTL) -n $(NS) create secret generic gateway-metrics --from-literal=password=$$(openssl rand -hex 16)
	@if [ "$(ANALYTICS)" = true ]; then $(MAKE) --no-print-directory elasticsearch; fi
	$(HELM) upgrade --install apim apim --repo $(GRAVITEE_REPO) --version $(APIM_VERSION) \
		-n $(NS) -f helm/apim.values.yaml $(APIM_EXTRA) --wait \
		--set gateway.services.core.http.authentication.password=$$($(KUBECTL) -n $(NS) get secret gateway-metrics -o jsonpath='{.data.password}' | base64 -d)
	$(KUBECTL) apply -f manifests/40-metrics-service.yaml
	$(KUBECTL) -n $(NS) rollout status deploy/pong --timeout=120s
	@echo "Ready. Run: make test"

up-analytics: ## Same as up, plus Elasticsearch analytics
	@$(MAKE) --no-print-directory up ANALYTICS=true

elasticsearch:
	$(KUBECTL) -n $(NS) get secret elasticsearch >/dev/null 2>&1 || \
		$(KUBECTL) -n $(NS) create secret generic elasticsearch --from-literal=password=$$(openssl rand -hex 16)
	$(KUBECTL) apply -f manifests/optional/elasticsearch.yaml
	$(KUBECTL) -n $(NS) rollout status statefulset/elasticsearch --timeout=300s

cluster:
	@kind get clusters | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config kind/cluster.yaml --wait 120s

test: ## Check /ping (verified and -k) and a 404 endpoint through the gateway
	@CTX=$(CTX) ./scripts/test.sh

test-analytics: ## Print the request metrics stored in Elasticsearch
	@CTX=$(CTX) ./scripts/test-analytics.sh

down: ## Remove everything
	kind delete cluster --name $(CLUSTER)
