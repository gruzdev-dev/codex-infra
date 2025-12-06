CLUSTER_NAME := codex
NAMESPACE := codex
INGRESS_NAMESPACE := ingress-nginx
IMAGE_TAG := 0.1.0
REPO_PREFIX := gruzdev-dev
SERVICES := auth documents files

.PHONY: init up down cluster ingress linkerd restart load deploy status
.PHONY: $(addprefix load-,$(SERVICES)) $(addprefix deploy-,$(SERVICES))

init: cluster ingress linkerd namespace
	@echo "Initialization environment completed"

up: init deploy
	@echo "Codex System is UP and RUNNING!"

down:
	kind delete cluster --name $(CLUSTER_NAME)

restart: down up

cluster:
	@echo "Creating Kind cluster..."
	kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml

ingress:
	@echo "Installing Nginx Ingress Controller..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml || true
	@echo "Waiting for Ingress..."
	kubectl wait --namespace $(INGRESS_NAMESPACE) \
	  --for=condition=ready pod \
	  --selector=app.kubernetes.io/component=controller \
	  --timeout=180s || echo "Ingress already ready"

linkerd:
	@echo "Installing Gateway API CRDs..."
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml || true
	@echo "Installing Linkerd Service Mesh..."
	linkerd install --crds | kubectl apply -f - || true
	linkerd install | kubectl apply -f - || true
	@echo "Waiting for Linkerd..."
	linkerd check

namespace:
	kubectl create namespace $(NAMESPACE) || echo "Namespace might already exist"

define load-service
docker build -t $(REPO_PREFIX)/codex-$(1):$(IMAGE_TAG) ../codex-$(1)
kind load docker-image $(REPO_PREFIX)/codex-$(1):$(IMAGE_TAG) --name $(CLUSTER_NAME)
endef

$(foreach svc,$(SERVICES),$(eval load-$(svc): ; $$(call load-service,$(svc))))

load: $(addprefix load-,$(SERVICES))

define deploy-service
helm upgrade --install codex-$(1) ./charts/codex \
	--namespace $(NAMESPACE) \
	-f ./releases/codex-$(1).yaml
endef

$(foreach svc,$(SERVICES),$(eval deploy-$(svc): load-$(svc) ; $$(call deploy-service,$(svc))))

deploy: $(addprefix deploy-,$(SERVICES))
	@echo "All services deployed via Helm."
	kubectl get pods -n $(NAMESPACE)

status:
	kubectl get pods -A -n $(NAMESPACE)