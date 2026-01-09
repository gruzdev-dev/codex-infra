CLUSTER_NAME := codex
NAMESPACE := codex
INGRESS_NAMESPACE := ingress-nginx
IMAGE_TAG := 0.1.0
REPO_PREFIX := gruzdev-dev
SERVICES := auth documents files

.PHONY: init up down cluster ingress linkerd restart load deploy redeploy status
.PHONY: $(addprefix load-,$(SERVICES)) $(addprefix deploy-,$(SERVICES)) $(addprefix redeploy-,$(SERVICES))

init: cluster ingress linkerd namespace
	@echo "Initialization environment completed"

up: init deploy
	@echo "Codex System is UP and RUNNING!"

down:
	kind delete cluster --name $(CLUSTER_NAME)

restart: down up

cluster:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster $(CLUSTER_NAME) already exists, skipping..."; \
	else \
		echo "Creating Kind cluster..."; \
		kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml; \
	fi

ingress:
	@if kubectl get namespace $(INGRESS_NAMESPACE) >/dev/null 2>&1 && \
		kubectl get pods -n $(INGRESS_NAMESPACE) --selector=app.kubernetes.io/component=controller >/dev/null 2>&1; then \
		echo "Nginx Ingress Controller already installed, skipping..."; \
	else \
		echo "Installing Nginx Ingress Controller..."; \
		kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml || true; \
		echo "Waiting for Ingress..."; \
		kubectl wait --namespace $(INGRESS_NAMESPACE) \
		  --for=condition=ready pod \
		  --selector=app.kubernetes.io/component=controller \
		  --timeout=180s || echo "Ingress already ready"; \
	fi

linkerd:
	@if kubectl get namespace linkerd >/dev/null 2>&1 && \
		kubectl get configmap linkerd-config -n linkerd >/dev/null 2>&1; then \
		echo "Linkerd already installed, skipping..."; \
	else \
		echo "Installing Gateway API CRDs..."; \
		kubectl apply --server-side=true -f https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.01/monthly-2026.01-install.yaml || true; \
		echo "Installing Linkerd Service Mesh..."; \
		linkerd install --crds | kubectl apply -f - || true; \
		linkerd install | kubectl apply -f - || true; \
		echo "Waiting for Linkerd pods to be ready..."; \
		kubectl wait --namespace linkerd --for=condition=ready pod --all --timeout=300s || true; \
		echo "Running Linkerd check..."; \
		linkerd check --wait=1m || echo "Linkerd check completed with warnings"; \
	fi
	
namespace:
	kubectl create namespace $(NAMESPACE) || echo "Namespace might already exist"

define load-service
docker build -t $(REPO_PREFIX)/codex-$(1):$(IMAGE_TAG) ../codex-$(1)
kind load docker-image $(REPO_PREFIX)/codex-$(1):$(IMAGE_TAG) --name $(CLUSTER_NAME)
endef

$(foreach svc,$(SERVICES),$(eval load-$(svc): ; $$(call load-service,$(svc))))

load: $(addprefix load-,$(SERVICES))

define deploy-service
helm upgrade --install $(1) ./charts/codex \
	--namespace $(NAMESPACE) \
	-f ./releases/$(1).yaml
endef

$(foreach svc,$(SERVICES),$(eval deploy-$(svc): load-$(svc) ; $$(call deploy-service,$(svc))))

deploy: $(addprefix deploy-,$(SERVICES))
	@echo "All services deployed via Helm."
	kubectl get pods -n $(NAMESPACE)

define redeploy-service
@kubectl rollout restart deployment/$(1) -n $(NAMESPACE) || echo "Deployment $(1) not found or already restarting"
endef

$(foreach svc,$(SERVICES),$(eval redeploy-$(svc): ; $$(call redeploy-service,$(svc))))

redeploy: $(addprefix redeploy-,$(SERVICES))
	@echo "All services restarted."
	@echo "Waiting for pods to be ready..."
	@kubectl wait --namespace $(NAMESPACE) \
	  --for=condition=ready pod \
	  --all \
	  --timeout=300s || echo "Some pods might still be starting"
	@kubectl get pods -n $(NAMESPACE)

status:
	kubectl get pods -A -n $(NAMESPACE)