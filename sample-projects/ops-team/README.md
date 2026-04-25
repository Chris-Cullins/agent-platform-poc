# Ops Team Agent System

## Purpose

This sample project defines a real, config-driven operations agent system for watching owned software systems, checking their health, and proposing remediation plans when something needs attention.

The goal is not a fake demo with hard-coded fixture responses. The goal is a local-to-real architecture that can start against a small set of real repos and Kubernetes resources, then grow into a platform pattern for operational agents.

## Summary

The Ops Team system runs a set of scheduled and on-demand agents responsible for specific operational scopes:

- Kubernetes workloads
- GitHub Actions / CI status
- deployment and rollout state
- service ownership metadata
- runbooks and architecture docs
- release readiness signals

Agents wake up on a schedule, inspect the systems assigned to them, decide whether action is needed, and produce one of three outcomes:

- `healthy`: no action needed
- `needs_attention`: human should review a finding
- `proposed_action`: agent recommends a concrete change, but does not execute it without approval

The initial system should be read-only plus propose-only. Any write/remediation path must go through human-in-the-loop approval.

## Non-Goals

- No automatic production remediation in the first version.
- No silent mutation of GitHub, Kubernetes, Jira, or deployment systems.
- No dependency on Microsoft Teams for the first local version.
- No company-specific secrets or system names in this public repo.
- No requirement that every workflow is declarative-only. BYO agents are allowed where workflow state and branching matter.

## High-Level Architecture

```text
Kubernetes CronJob / manual trigger
  -> ops-wakeup job
    -> kagent A2A invoke
      -> ops-orchestrator-agent
        -> k8s-health-agent
        -> ci-health-agent
        -> rollout-health-agent
        -> docs-runbook-agent
        -> ownership-agent
        -> remediation-planner-agent
      -> observation store
      -> approval inbox
      -> notification adapter
```

## Runtime Choice

Use both kagent declarative agents and BYO agents.

### Declarative kagent agents

Use declarative agents for narrow, tool-oriented specialists:

- `k8s-health-agent`
- `ci-health-agent`
- `rollout-health-agent`
- `docs-runbook-agent`
- `ownership-agent`

These agents are mostly prompt plus tools. They inspect one domain and return structured findings.

### BYO LangGraph agent

Use a BYO LangGraph agent for the orchestrator:

- `ops-orchestrator-agent`

The orchestrator needs deterministic workflow behavior:

- load config
- fan out checks
- merge findings
- classify severity
- decide whether remediation planning is needed
- create approval records
- avoid duplicate alerts
- preserve run state
- retry failed checks selectively

That is awkward as prompt-only behavior and better expressed as code.

The BYO agent should still run under kagent so invocation, A2A, model config, tool access, and UI debugging remain consistent with the rest of the stack.

## Configuration Model

The system is driven by a checked-in config file plus Kubernetes Secrets for credentials.

Example file:

```yaml
apiVersion: ops-team.agent-platform.local/v1alpha1
kind: OpsTeamConfig
metadata:
  name: local-ops-team

tenant:
  tenant_id: platform-reference
  app_id: ops-team-sandbox

schedule:
  default_interval: 15m
  quiet_hours:
    timezone: America/Chicago
    start: "18:00"
    end: "07:00"

systems:
  - id: agent-platform-poc
    name: Agent Platform POC
    owner:
      team: platform
      escalation: local
    kubernetes:
      contexts:
        - name: kind-agent-platform-poc
          namespaces:
            - kagent
            - toolhive-system
            - agentgateway-system
            - platform-reference
          watch:
            deployments: true
            statefulsets: true
            pods: true
            events: true
    github:
      repositories:
        - owner: Chris-Cullins
          name: agent-platform-poc
          branches:
            - main
          workflows:
            - "*"
    rollout:
      provider: kubernetes
      strategy: deployment
    docs:
      runbooks:
        - docs/local-stack.md
        - README.md
    policies:
      max_severity_without_human: medium
      allow_write_actions: false
      allow_restart_proposals: true
      allow_rollback_proposals: true
```

Credentials should be referenced by name, not stored in the config:

```yaml
integrations:
  github:
    auth_secret_ref:
      namespace: ops-team
      name: github-token
      key: token
  kubernetes:
    mode: in_cluster
  notifications:
    provider: local_approval_inbox
```

## Agent Roles

### ops-orchestrator-agent

Owns workflow coordination.

Responsibilities:

- load `OpsTeamConfig`
- decide which systems are due for checks
- invoke specialist agents
- normalize findings
- classify severity
- deduplicate repeated findings
- request remediation plans when needed
- create approval records
- emit notifications

Output shape:

```yaml
run_id: opsrun-2026-04-25T10-15-00
system_id: agent-platform-poc
status: needs_attention
severity: medium
summary: kagent kmcp controller restarted 3 times in the last hour
findings:
  - source: k8s-health-agent
    severity: medium
    signal: restart_count_increase
    evidence:
      namespace: kagent
      pod: kagent-kmcp-controller-manager
      restart_count: 3
recommended_next_step: inspect controller logs and recent CRD changes
approval_required: false
```

### k8s-health-agent

Checks Kubernetes resources assigned in config.

Read tools:

- list namespaces
- list deployments/statefulsets/pods
- get events
- get pod logs
- describe failing resources
- inspect resource pressure

Signals:

- pod not ready
- crash loops
- high restarts
- failed scheduling
- image pull failures
- unhealthy rollout
- recent warning events
- resource pressure

Propose-only actions:

- restart deployment
- rollback deployment
- scale deployment
- collect deeper diagnostics

### ci-health-agent

Checks GitHub Actions for configured repositories.

Read tools:

- list workflow runs
- get workflow run
- get failed job logs
- compare recent commits
- read CODEOWNERS

Signals:

- failed main branch workflow
- repeated flaky test
- release-blocking failure
- missing required workflow
- failure after recent dependency change

Propose-only actions:

- rerun workflow
- open issue
- assign owner
- post PR comment

### rollout-health-agent

Checks deployment and promotion state.

Initial provider can be plain Kubernetes Deployments. Later providers can include Argo CD or Argo Rollouts.

Signals:

- rollout stuck
- image changed recently
- desired and available replicas mismatch
- deployment drift from Git
- promotion blocked by unhealthy dependency

Propose-only actions:

- rollback to previous revision
- pause rollout
- promote rollout
- sync app

### docs-runbook-agent

Finds relevant runbooks and checks whether operational docs appear stale.

Read tools:

- repo file search
- docs search
- runbook lookup

Signals:

- runbook missing
- runbook references non-existent service
- known failure mode found
- docs disagree with current deployment config

### ownership-agent

Maps findings to responsible teams and escalation paths.

Read tools:

- CODEOWNERS
- service catalog
- repo metadata
- config owner block

Output:

```yaml
owner_team: platform
confidence: high
escalation_target: local
reason: namespace kagent is owned by platform in OpsTeamConfig
```

### remediation-planner-agent

Creates a plan but does not execute it.

Plan format:

```yaml
plan_id: plan-123
summary: Restart kagent kmcp controller after confirming no CRD migration is running
risk: low
requires_approval: true
steps:
  - type: read
    command: kubectl logs -n kagent deploy/kagent-kmcp-controller-manager --tail=200
  - type: read
    command: kubectl get events -n kagent --sort-by=.lastTimestamp
  - type: propose
    action: restart_deployment
    target:
      namespace: kagent
      deployment: kagent-kmcp-controller-manager
rollback:
  - no persistent state change expected
approval:
  required_role: operator
  approval_channel: local_approval_inbox
```

## Trigger Model

### Scheduled checks

Use Kubernetes `CronJob` as the wakeup mechanism.

Example:

```text
CronJob ops-team-wakeup
  -> loads config
  -> invokes ops-orchestrator-agent over kagent A2A
  -> stores run result
```

The CronJob should not contain business logic. It should only wake the orchestrator with a task:

```json
{
  "task_type": "scheduled_health_check",
  "config_ref": "ops-team/local-ops-team",
  "scope": "all_due_systems",
  "triggered_by": "cron"
}
```

### Manual checks

Manual trigger options:

- kagent UI chat
- `kagent invoke`
- a small local CLI
- a local HTTP endpoint

Example:

```sh
kagent invoke \
  --namespace ops-team \
  --agent ops-orchestrator-agent \
  --task 'Run a health check for system agent-platform-poc and propose fixes only.'
```

### Event-driven checks

Later, add webhooks:

- GitHub workflow failure webhook
- deployment event webhook
- alertmanager webhook

These should enqueue work or call the orchestrator A2A endpoint with a scoped task.

## Human-In-The-Loop

Start with a local approval inbox instead of Teams.

### Phase 1: local approval inbox

Create an `ApprovalRequest` custom resource or a simple persisted JSON record.

Example:

```yaml
apiVersion: ops-team.agent-platform.local/v1alpha1
kind: ApprovalRequest
metadata:
  name: plan-123
  namespace: ops-team
spec:
  system_id: agent-platform-poc
  plan_id: plan-123
  summary: Restart kagent kmcp controller
  risk: low
  requested_by: ops-orchestrator-agent
  actions:
    - type: restart_deployment
      namespace: kagent
      deployment: kagent-kmcp-controller-manager
  status: pending
```

Approval command:

```sh
kubectl patch approvalrequest plan-123 \
  -n ops-team \
  --type merge \
  -p '{"spec":{"status":"approved","approved_by":"chris"}}'
```

An executor watches approved requests and performs the action.

This keeps the first version Kubernetes-native, auditable, and easy to debug.

### Phase 2: GitHub issue or PR approval

For CI and repo workflows, create a GitHub issue with the proposed plan. A human approves by applying a label such as:

```text
ops-agent-approved
```

The executor only acts on labeled plans.

### Phase 3: Microsoft Teams

Teams can come later as a notification and approval surface.

Options:

- Teams incoming webhook for notifications only
- Power Automate flow that updates an `ApprovalRequest`
- Bot Framework adapter for richer approve/reject actions
- MCP server for Teams if a safe internal one exists

Teams should not be the system of record for approval. The approval record should live in Kubernetes or another auditable backend.

## Data Model

### Observation

```yaml
run_id: string
system_id: string
agent: string
timestamp: string
status: healthy | warning | critical | unknown
signals: []
evidence: {}
raw_refs: []
```

### Finding

```yaml
finding_id: string
system_id: string
severity: low | medium | high | critical
source_agent: string
summary: string
evidence: []
first_seen: string
last_seen: string
dedupe_key: string
```

### Plan

```yaml
plan_id: string
finding_ids: []
risk: low | medium | high
requires_approval: true
actions: []
rollback: []
status: proposed | approved | rejected | executed | failed
```

## Tooling

### MCP tools

Initial real MCP servers:

- Kubernetes MCP/tool access through kagent built-in tools
- GitHub MCP server or GitHub API adapter
- repo filesystem/search tool for checked-out repos
- notification adapter
- approval inbox adapter

Potential later tools:

- Argo CD
- Jira
- Confluence
- PagerDuty
- Datadog or Grafana
- service catalog

### Tool safety levels

Every tool should be classified:

```yaml
tools:
  k8s.get_pods:
    risk: read
  k8s.get_logs:
    risk: read
  github.get_workflow_run:
    risk: read
  github.rerun_workflow:
    risk: write_requires_approval
  k8s.restart_deployment:
    risk: write_requires_approval
  teams.post_message:
    risk: write_requires_approval
```

## Namespaces

Use a dedicated namespace:

```text
ops-team
```

Suggested resources:

```text
ops-team-config ConfigMap
ops-orchestrator-agent Agent
k8s-health-agent Agent
ci-health-agent Agent
rollout-health-agent Agent
docs-runbook-agent Agent
ownership-agent Agent
ops-team-wakeup CronJob
approval-inbox service or CRD
```

## First Implementation Slice

Build the smallest real version:

1. Add `ops-team` namespace.
2. Add `OpsTeamConfig` as a ConfigMap.
3. Create declarative `k8s-health-agent`.
4. Create declarative `ci-health-agent`.
5. Create BYO or simple declarative `ops-orchestrator-agent`.
6. Add CronJob that invokes the orchestrator every 15 minutes.
7. Write findings to a ConfigMap or lightweight SQLite/Postgres store.
8. Write proposed actions as `ApprovalRequest` records.
9. Add a local approval CLI or `kubectl patch` approval flow.

The first real target can be this repo and the local kind cluster:

- GitHub repo: `Chris-Cullins/agent-platform-poc`
- Kubernetes context: `kind-agent-platform-poc`
- namespaces: `kagent`, `toolhive-system`, `agentgateway-system`, `platform-reference`

## Open Questions

- Should `ApprovalRequest` be a real CRD or a simple ConfigMap-backed record for the first sample?
- Should the orchestrator start as declarative and move to BYO LangGraph once branching gets complex?
- Which GitHub integration should be first: GitHub MCP server, direct GitHub API tool, or `gh` wrapper tool?
- Should the scheduled wakeup be one global CronJob or one CronJob per system?
- Where should run history live locally: Kubernetes objects, SQLite, Postgres, or Langfuse traces once observability is added back?

## Recommended Starting Decisions

- Use one global CronJob for the first version.
- Use the local kind cluster and this GitHub repo as real targets.
- Use declarative specialist agents.
- Use BYO LangGraph for orchestration once the first declarative prototype proves the tool contracts.
- Use Kubernetes-native `ApprovalRequest` records for human-in-the-loop.
- Keep Teams as a notification adapter, not the approval system of record.

