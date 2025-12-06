CLUSTER_NAME := codex
NAMESPACE := codex
INGRESS_NAMESPACE := ingress-nginx
IMAGE_TAG := 0.1.0
REPO_PREFIX := gruzdev-dev

.PHONY: init up down cluster ingress linkerd restart load-auth load-docs load-files deploy deploy-auth deploy-docs deploy-files status

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

load-auth:
	docker build -t $(REPO_PREFIX)/codex-auth:$(IMAGE_TAG) ../codex-auth
	kind load docker-image $(REPO_PREFIX)/codex-auth:$(IMAGE_TAG) --name $(CLUSTER_NAME)

load-docs:
	docker build -t $(REPO_PREFIX)/codex-documents:$(IMAGE_TAG) ../codex-documents
	kind load docker-image $(REPO_PREFIX)/codex-documents:$(IMAGE_TAG) --name $(CLUSTER_NAME)

load-files:
	docker build -t $(REPO_PREFIX)/codex-files:$(IMAGE_TAG) ../codex-files
	kind load docker-image $(REPO_PREFIX)/codex-files:$(IMAGE_TAG) --name $(CLUSTER_NAME)

deploy: deploy-auth deploy-docs deploy-files
	@echo "All services deployed via Helm."
	kubectl get pods -n $(NAMESPACE)

deploy-auth: load-auth
	helm upgrade --install codex-auth ./charts/codex \
		--namespace $(NAMESPACE) \
		-f ./releases/codex-auth.yaml \
		--set image.tag=$(IMAGE_TAG) \
		--set env[0].name=SERVER_PORT \
		--set-string env[0].value=8080

deploy-docs: load-docs
	helm upgrade --install codex-documents ./charts/codex \
		--namespace $(NAMESPACE) \
		-f ./releases/codex-documents.yaml \
		--set image.tag=$(IMAGE_TAG) \
		--set env[0].name=SERVER_PORT \
		--set-string env[0].value=8081

deploy-files: load-files
	helm upgrade --install codex-files ./charts/codex \
		--namespace $(NAMESPACE) \
		-f ./releases/codex-files.yaml \
		--set image.tag=$(IMAGE_TAG) \
		--set env[0].name=SERVER_PORT \
		--set-string env[0].value=8082

status:
	kubectl get pods -A -n $(NAMESPACE)