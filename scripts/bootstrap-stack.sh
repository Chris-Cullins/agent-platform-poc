#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agent-platform-poc}"
KAGENT_PROFILE="${KAGENT_PROFILE:-minimal}"
KAGENT_INSTALL_KEY="${OPENAI_API_KEY:-local-placeholder-not-for-model-calls}"

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

if ! command -v kagent >/dev/null 2>&1; then
  echo "kagent is required. Install with: brew install kagent"
  exit 1
fi

colima start --cpu 4 --memory 8 --disk 60

if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

OPENAI_API_KEY="${KAGENT_INSTALL_KEY}" kagent install --profile "${KAGENT_PROFILE}"

helm upgrade -i toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds
helm upgrade -i toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  -n toolhive-system \
  --create-namespace

kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

helm upgrade -i --create-namespace --namespace agentgateway-system --version v2.2.1 \
  agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds
helm upgrade -i -n agentgateway-system --version v2.2.1 \
  agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway

helm upgrade --install agent-platform-poc ./charts/agent-platform-poc \
  -n agent-platform-poc \
  --create-namespace

kubectl get pods -A

