#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agent-platform-poc}"
KAGENT_INSTALL_KEY="${OPENAI_API_KEY:-local-placeholder-not-for-model-calls}"
KAGENT_VERSION="${KAGENT_VERSION:-0.9.0}"
TOOLHIVE_VERSION="${TOOLHIVE_VERSION:-0.24.1}"
AGENTGATEWAY_VERSION="${AGENTGATEWAY_VERSION:-v2.2.1}"

if ! command -v colima >/dev/null 2>&1; then
  echo "colima is required. Install with: brew install colima"
  exit 1
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "kind is required. Install with: brew install kind"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required."
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required. Install with: brew install helm"
  exit 1
fi

colima start --cpu 4 --memory 8 --disk 60

if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

helm upgrade -i kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent \
  --create-namespace \
  --version "${KAGENT_VERSION}"

helm upgrade -i kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --version "${KAGENT_VERSION}" \
  -f helm-values/kagent-minimal.yaml \
  --set providers.openAI.apiKey="${KAGENT_INSTALL_KEY}"

helm upgrade -i toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds \
  --version "${TOOLHIVE_VERSION}"
helm upgrade -i toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  -n toolhive-system \
  --create-namespace \
  --version "${TOOLHIVE_VERSION}" \
  -f helm-values/toolhive-operator.yaml

kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system --version "${AGENTGATEWAY_VERSION}" \
  agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds
helm upgrade -i -n agentgateway-system --version "${AGENTGATEWAY_VERSION}" \
  agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway \
  -f helm-values/agentgateway.yaml

helm upgrade --install agent-platform-poc ./charts/agent-platform-poc \
  -n agent-platform-poc \
  --create-namespace

kubectl get pods -A
