# Helm Values

These files pin the local stack configuration that sits above the kind cluster.

- `kagent-minimal.yaml`: installs kagent with built-in demo agents disabled.
- `toolhive-operator.yaml`: enables the ToolHive operator features used by the sandbox.
- `agentgateway.yaml`: local AgentGateway settings.

The local sandbox chart lives in `charts/agent-platform-poc` and owns resources we define ourselves, such as the reference tenant, ToolHive MCP server, and OpenRouter `ModelConfig`.

API keys are passed at install time and should not be committed.

