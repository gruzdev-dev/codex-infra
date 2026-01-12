CLUSTER_NAME := codex
NAMESPACE := codex
INGRESS_NAMESPACE := ingress-nginx
IMAGE_TAG := 0.1.0
REPO_PREFIX := gruzdev-dev
SERVICES := auth documents files

INGRESS_URL := https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.1/deploy/static/provider/kind/deploy.yaml
GATEWAY_API_URL   := https://github.com/kubernetes-sigs/gateway-api/releases/download/monthly-2026.01/monthly-2026.01-install.yaml

RED    := $(shell tput -Txterm setaf 1)
GREEN  := $(shell tput -Txterm setaf 2)
YELLOW := $(shell tput -Txterm setaf 3)
RESET  := $(shell tput -Txterm sgr0)

.PHONY: init up down cluster ingress linkerd restart load deploy deploy-minio redeploy status
.PHONY: $(addprefix load-,$(SERVICES)) $(addprefix deploy-,$(SERVICES)) $(addprefix redeploy-,$(SERVICES))

init: cluster ingress linkerd namespace
	@echo "Initialization environment completed"

down:
	kind delete cluster --name $(CLUSTER_NAME)

restart: down init deploy

cluster:
	@printf "$(YELLOW)Checking Kind cluster '$(CLUSTER_NAME)'...$(RESET) "
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "$(GREEN)[ALREADY EXISTS]$(RESET)"; \
	else \
		echo "$(YELLOW)[CREATING]$(RESET)"; \
		kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml; \
		echo "$(GREEN)[CLUSTER READY]$(RESET)"; \
	fi

ingress:
	@printf "$(YELLOW)Checking Ingress Controller (Kind)...$(RESET) "
	@if kubectl get pod -n $(INGRESS_NAMESPACE) -l app.kubernetes.io/component=controller -o name 2>/dev/null | grep -q . ; then \
		echo "$(GREEN)[ALREADY INSTALLED]$(RESET)"; \
	else \
		echo "$(YELLOW)[INSTALLING]$(RESET)"; \
		(kubectl apply -f $(INGRESS_URL) && \
		 echo "Waiting for ingress pods..." && \
		 kubectl wait -n $(INGRESS_NAMESPACE) --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s && \
		 echo "$(GREEN)[OK]$(RESET)") || \
		(echo "$(RED)[FAILED]$(RESET)"; exit 1); \
	fi

linkerd:
	@printf "$(YELLOW)Checking Linkerd Service Mesh...$(RESET) "
	@if kubectl get ns linkerd >/dev/null 2>&1 && kubectl get cm linkerd-config -n linkerd >/dev/null 2>&1; then \
		echo "$(GREEN)[ALREADY INSTALLED]$(RESET)"; \
	else \
		echo "$(YELLOW)[INSTALLING]$(RESET)"; \
		printf "  $(YELLOW)→ Applying Gateway API CRDs...$(RESET)\n"; \
		(kubectl apply --server-side=true -f $(GATEWAY_API_URL) && \
		 printf "  $(YELLOW)→ Installing Linkerd...$(RESET)\n" && \
		 linkerd install --crds | kubectl apply -f - && \
		 linkerd install | kubectl apply -f - && \
		 echo "Waiting for Linkerd pods..." && \
		 kubectl wait -n linkerd --for=condition=ready pod --all --timeout=300s && \
		 linkerd check && \
		 echo "$(GREEN)[OK]$(RESET)") || \
		(echo "$(RED)[FAILED]$(RESET)"; exit 1); \
	fi

namespace:
	@printf "$(YELLOW)Checking namespace '$(NAMESPACE)'...$(RESET) "
	@if kubectl get ns $(NAMESPACE) >/dev/null 2>&1; then \
		echo "$(GREEN)[ALREADY EXISTS]$(RESET)"; \
	else \
		kubectl create ns $(NAMESPACE) >/dev/null && echo "$(GREEN)[CREATED]$(RESET)"; \
	fi

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

deploy-minio:
	helm upgrade --install minio ./charts/minio \
		--namespace $(NAMESPACE) \
		-f ./releases/minio.yaml
	@echo "MinIO deployed via Helm."
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=minio

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

define delete-service
@printf "$(YELLOW)Deleting service '$(1)'...$(RESET) "
@kubectl delete all,cm,secret,pvc -n $(NAMESPACE) \
	-l app.kubernetes.io/instance=$(1) \
	--ignore-not-found || (echo "$(RED)[FAILED]$(RESET)"; exit 1)
@echo "$(GREEN)[DELETED]$(RESET)"
endef

$(foreach svc,$(SERVICES),$(eval delete-$(svc): ; $$(call delete-service,$(svc))))

delete: $(addprefix delete-,$(SERVICES))
	@echo "All services deleted."

status:
	kubectl get pods -A -n $(NAMESPACE)