CLUSTER_NAME := codex-cluster
IMAGE_TAG := 0.1.0
REPO_PREFIX := gruzdev-dev

.PHONY: up down restart

up: cluster ingress linkerd images deploy-all
	@echo "🚀 Codex System (Auth, Docs, Files) is UP and RUNNING!"

down:
	kind delete cluster --name $(CLUSTER_NAME)

restart: down up

.PHONY: cluster ingress linkerd

cluster:
	@echo "🔧 Creating Kind cluster..."
	kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml || echo "Cluster might already exist"

ingress:
	@echo "🚪 Installing Nginx Ingress Controller..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	@echo "💤 Giving K8s a moment to create pods..."
	sleep 10
	@echo "⏳ Waiting for Ingress..."
	kubectl wait --namespace ingress-nginx \
	  --for=condition=ready pod \
	  --selector=app.kubernetes.io/component=controller \
	  --timeout=180s

linkerd:
	@echo "🛡️ Installing Linkerd Service Mesh..."
	linkerd install --crds | kubectl apply -f -
	linkerd install | kubectl apply -f -
	@echo "⏳ Waiting for Linkerd..."
	linkerd check

.PHONY: images build-auth load-auth build-docs load-docs build-files load-files

images: build-auth load-auth build-docs load-docs build-files load-files
	@echo "🐳 All images built and loaded."

build-auth:
	docker build -t $(REPO_PREFIX)/codex-auth:$(IMAGE_TAG) ../codex-auth
load-auth:
	kind load docker-image $(REPO_PREFIX)/codex-auth:$(IMAGE_TAG) --name $(CLUSTER_NAME)

build-docs:
	docker build -t $(REPO_PREFIX)/codex-documents:$(IMAGE_TAG) ../codex-documents
load-docs:
	kind load docker-image $(REPO_PREFIX)/codex-documents:$(IMAGE_TAG) --name $(CLUSTER_NAME)

build-files:
	docker build -t $(REPO_PREFIX)/codex-files:$(IMAGE_TAG) ../codex-files
load-files:
	kind load docker-image $(REPO_PREFIX)/codex-files:$(IMAGE_TAG) --name $(CLUSTER_NAME)

.PHONY: deploy-all deploy-auth deploy-docs deploy-files

deploy-all: deploy-auth deploy-docs deploy-files
	@echo "✅ All services deployed via Helm."

deploy-auth:
	helm upgrade --install codex-auth ./charts/codex-service-chart \
		-f ./releases/production/codex-auth.yaml \
		--set image.tag=$(IMAGE_TAG) \
		--set env[0].name=SERVER_PORT \
		--set env[0].value="8080"

deploy-docs:
	helm upgrade --install codex-documents ./charts/codex-service-chart \
		-f ./releases/production/codex-documents.yaml \
		--set image.tag=$(IMAGE_TAG) \
		--set env[0].name=SERVER_PORT \
		--set env[0].value="8081"

deploy-files:
	helm upgrade --install codex-files ./charts/codex-service-chart \
		-f ./releases/production/codex-files.yaml \
		--set image.tag=$(IMAGE_TAG) \
		--set env[0].name=SERVER_PORT \
		--set env[0].value="8082"

status:
	kubectl get pods -A