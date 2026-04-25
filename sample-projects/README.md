# Sample Projects

This folder is for small workflow experiments against the local agent platform stack.

Initial candidates:

- `scheduled-agent`: Kubernetes `CronJob` invokes a kagent agent on a timer.
- `agent-handoff`: an orchestrator agent delegates to specialist agents over kagent A2A.
- `ci-triage-agent`: a CI failure triage workflow using GitHub, logs, and ownership tools.
- `k8s-incident-agent`: a read-only Kubernetes diagnosis workflow intended for chat-triggered use.

Keep samples small and isolated. Each sample should include:

- what triggers the workflow
- which agent receives the request
- which tools are allowed
- what is read-only versus side-effecting
- how to run it locally

