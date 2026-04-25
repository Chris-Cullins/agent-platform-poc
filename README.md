# Agent Platform POC

Local sandbox for experimenting with a Kubernetes-native agent platform stack:

- kagent for agent runtime and A2A invocation
- ToolHive for MCP server lifecycle and tool gatewaying
- AgentGateway for gateway experiments
- OpenRouter-backed kagent model configs for local LLM usage

This repo intentionally keeps secrets out of source. Create API key secrets with `kubectl` commands or local environment variables.

## Current Local Stack

The local cluster was created with:

```sh
colima start --cpu 4 --memory 8 --disk 60
kind create cluster --name agent-platform-poc --wait 120s
```

Core components:

```sh
scripts/bootstrap-stack.sh
```

Sandbox-owned resources are managed by the chart in `charts/agent-platform-poc`.

```sh
helm upgrade --install agent-platform-poc ./charts/agent-platform-poc -n agent-platform-poc --create-namespace
```

Third-party chart values are in `helm-values/`.

## kagent UI

```sh
kubectl port-forward -n kagent svc/kagent-ui 8082:8080
kubectl port-forward -n kagent svc/kagent-controller 8083:8083
```

Open:

```text
http://localhost:8082
```

## OpenRouter

Create the API key secret without committing the key:

```sh
export OPENROUTER_API_KEY='your-key'

kubectl create secret generic kagent-openrouter \
  -n kagent \
  --from-literal OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The chart creates a kagent `ModelConfig` named `openrouter-kimi-k2-6` for `moonshotai/kimi-k2.6`.

## Sample Projects

See `sample-projects/` for workflow experiments.
