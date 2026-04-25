# Local Agent Platform Stack

This repo is a local sandbox for the Tiger Team agent platform ideas.

## Current Cluster

- Runtime: Colima Docker VM
- Kubernetes: kind cluster `agent-platform-poc`
- kube context: `kind-agent-platform-poc`

## Installed Components

- `kagent` in namespace `kagent`
- ToolHive operator in namespace `toolhive-system`
- AgentGateway in namespace `agentgateway-system`
- Reference tenant namespace `platform-reference`
- Sandbox Helm release `agent-platform-poc` in namespace `agent-platform-poc`

Langfuse is intentionally not part of the default single-node kind stack right now. It was too heavy for the initial 4 CPU / 8 GB Colima VM and caused control-plane pressure.

## Useful Commands

```sh
colima start
kubectl config use-context kind-agent-platform-poc
kubectl get pods -A
helm list -A
```

Port-forward the kagent UI:

```sh
kubectl port-forward -n kagent svc/kagent-ui 8082:8080
```

Port-forward the kagent A2A/controller API:

```sh
kubectl port-forward -n kagent svc/kagent-controller 8083:8083
```

Apply the reference ToolHive MCP server:

```sh
helm upgrade --install agent-platform-poc ./charts/agent-platform-poc -n agent-platform-poc --create-namespace
```

## OpenRouter With kagent

kagent does not need a dedicated OpenRouter provider. Use the OpenAI provider with a custom base URL:

```yaml
provider: OpenAI
model: moonshotai/kimi-k2.6
openAI:
  baseUrl: https://openrouter.ai/api/v1
```

Create the secret without committing the key:

```sh
kubectl create secret generic kagent-openrouter \
  -n kagent \
  --from-literal OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then apply or update the local chart:

```sh
helm upgrade --install agent-platform-poc ./charts/agent-platform-poc -n agent-platform-poc --create-namespace
```

## Notes

The initial `kagent` install used a placeholder OpenAI key only to satisfy the installer. Replace the model/provider secret before making real model calls.
