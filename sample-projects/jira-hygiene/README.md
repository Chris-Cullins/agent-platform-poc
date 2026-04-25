# Jira Hygiene Agent Workflow

## Purpose

This sample project defines a real, config-driven Jira hygiene workflow for keeping issue queues cleaner without letting an agent silently edit project-tracking data.

The workflow scans configured Jira projects and boards on a schedule, classifies issues that need attention, proposes cleanup actions, and routes those proposals through human approval before any write happens.

## Summary

The Jira Hygiene workflow is a scheduled background agent system.

It watches configured Jira scopes such as:

- new untriaged tickets
- stale tickets
- tickets missing owners
- tickets missing acceptance criteria
- possible duplicates
- tickets with unclear priority
- blocked tickets
- tickets in the wrong component or project area
- sprint items at risk

The agent produces one of three outcomes per issue:

- `no_action`: issue looks acceptable
- `needs_review`: human should inspect the issue
- `proposed_update`: agent proposes concrete Jira updates, but does not apply them without approval

Initial behavior should be read-only plus propose-only.

## Non-Goals

- No automatic Jira mutation in the first version.
- No private Jira project names or company-specific metadata in this public repo.
- No dependency on Microsoft Teams for the first local version.
- No replacement for product owner or engineering manager judgment.
- No fully autonomous sprint planning.

## High-Level Architecture

```text
Kubernetes CronJob / manual trigger
  -> jira-hygiene-wakeup job
    -> kagent A2A invoke
      -> jira-hygiene-orchestrator-agent
        -> jira-classifier-agent
        -> duplicate-detector-agent
        -> acceptance-criteria-agent
        -> ownership-agent
        -> priority-review-agent
        -> hygiene-digest-agent
      -> hygiene findings store
      -> approval inbox
      -> notification adapter
      -> optional Jira executor
```

## Runtime Choice

Use both kagent declarative agents and a BYO orchestrator.

### Declarative kagent agents

Use declarative agents for focused analysis:

- `jira-classifier-agent`
- `duplicate-detector-agent`
- `acceptance-criteria-agent`
- `ownership-agent`
- `priority-review-agent`
- `hygiene-digest-agent`

These agents mostly read Jira data, repo ownership files, and project config, then return structured findings.

### BYO LangGraph agent

Use a BYO LangGraph agent for:

- `jira-hygiene-orchestrator-agent`

The orchestrator needs deterministic behavior:

- load hygiene config
- query Jira with configured JQL
- chunk issue batches
- fan out issue analysis
- deduplicate findings
- avoid repeatedly nagging on the same issue
- create approval requests
- optionally execute approved updates
- produce digests

That workflow is better as code than as prompt-only behavior.

## Configuration Model

The system is driven by a checked-in config file plus Kubernetes Secrets for credentials.

Example:

```yaml
apiVersion: jira-hygiene.agent-platform.local/v1alpha1
kind: JiraHygieneConfig
metadata:
  name: local-jira-hygiene

tenant:
  tenant_id: platform-reference
  app_id: jira-hygiene-sandbox

schedule:
  default_interval: 12h
  timezone: America/Chicago
  quiet_hours:
    start: "18:00"
    end: "07:00"

jira:
  site: example.atlassian.net
  auth_secret_ref:
    namespace: jira-hygiene
    name: jira-api-token
    key: token

scopes:
  - id: platform-board
    name: Platform Board
    owner:
      team: platform
      escalation: local
    jql: >
      project = PLATFORM
      AND statusCategory != Done
      ORDER BY updated ASC
    limits:
      max_issues_per_run: 50
      max_age_days_before_stale: 14
    components:
      allowed:
        - agent-platform
        - developer-experience
        - infrastructure
    labels:
      managed_prefixes:
        - hygiene/
        - agent-proposed/
    policies:
      allow_write_actions: false
      require_approval_for_labels: true
      require_approval_for_assignment: true
      require_approval_for_priority_change: true
      require_approval_for_status_transition: true
      max_changes_per_issue: 3
```

Optional repo ownership config:

```yaml
repositories:
  - owner: Chris-Cullins
    name: agent-platform-poc
    codeowners_path: CODEOWNERS
    component_mapping:
      charts/: infrastructure
      scripts/: developer-experience
      sample-projects/: agent-platform
```

## Agent Roles

### jira-hygiene-orchestrator-agent

Owns the scheduled workflow.

Responsibilities:

- load `JiraHygieneConfig`
- run configured JQL searches
- batch issues
- invoke specialist agents
- normalize findings
- deduplicate repeated findings
- create proposed updates
- create approval records
- emit digest output

Output shape:

```yaml
run_id: jirahygiene-2026-04-25T10-15-00
scope_id: platform-board
status: needs_review
issues_scanned: 50
findings_count: 12
proposed_updates_count: 7
digest:
  summary: 12 issues need hygiene review. 4 are stale, 3 are missing acceptance criteria, 2 may be duplicates.
  top_items:
    - issue: PLATFORM-123
      reason: stale for 28 days and no assignee
      recommendation: assign owner or move to backlog
```

### jira-classifier-agent

Classifies issue type and project area.

Read inputs:

- issue title
- issue description
- labels
- component
- linked PRs
- linked epics
- comments

Findings:

- likely bug
- likely feature
- likely platform support request
- likely incident follow-up
- likely duplicate
- unclear type

Proposed updates:

```yaml
issue: PLATFORM-123
updates:
  - field: labels
    add:
      - hygiene/type-platform-support
  - field: component
    set: developer-experience
requires_approval: true
```

### duplicate-detector-agent

Finds possible duplicates using Jira search and semantic comparison.

Signals:

- same error text
- same service name
- same stack trace
- same user request
- same linked PR or incident

Output:

```yaml
issue: PLATFORM-123
possible_duplicates:
  - issue: PLATFORM-98
    confidence: medium
    reason: same failing deployment and same namespace
recommendation: ask owner to close or link duplicate
```

### acceptance-criteria-agent

Checks whether the issue has enough detail to be actionable.

Signals:

- missing expected behavior
- missing actual behavior
- missing reproduction steps
- missing acceptance criteria
- missing environment
- missing screenshots/logs for support issue

Proposed comment:

```yaml
issue: PLATFORM-123
comment: |
  This issue looks actionable after adding:
  - expected behavior
  - affected environment
  - acceptance criteria
requires_approval: true
```

### ownership-agent

Maps issues to owning team or likely assignee.

Read tools:

- Jira components
- CODEOWNERS
- service catalog
- repository paths
- configured team ownership

Proposed updates:

- assign issue
- add component
- add team label
- mention owner in proposed comment

### priority-review-agent

Checks whether priority looks inconsistent with impact.

Signals:

- production incident follow-up marked low
- internal docs typo marked critical
- stale high-priority issue with no owner
- sprint commitment without acceptance criteria

Proposed updates:

- suggest priority change
- request owner review
- flag as sprint risk

### hygiene-digest-agent

Creates human-readable summaries for review.

Digest destinations:

- local approval inbox
- GitHub issue
- Markdown report
- Teams message later

Digest shape:

```markdown
# Jira Hygiene Digest

Scope: Platform Board
Scanned: 50 issues
Needs review: 12
Proposed updates: 7

## Highest Priority

- PLATFORM-123: stale 28 days, no assignee
- PLATFORM-130: possible duplicate of PLATFORM-98
- PLATFORM-141: missing acceptance criteria and currently in active sprint
```

## Trigger Model

### Scheduled scan

Use Kubernetes `CronJob`.

Example:

```text
CronJob jira-hygiene-wakeup
  -> invokes jira-hygiene-orchestrator-agent over kagent A2A
  -> scope: all configured Jira scopes due for review
```

Task payload:

```json
{
  "task_type": "scheduled_jira_hygiene_scan",
  "config_ref": "jira-hygiene/local-jira-hygiene",
  "scope": "all_due_scopes",
  "mode": "propose_only",
  "triggered_by": "cron"
}
```

### Manual scan

Use kagent UI or CLI:

```sh
kagent invoke \
  --namespace jira-hygiene \
  --agent jira-hygiene-orchestrator-agent \
  --task 'Run a propose-only hygiene scan for the platform-board scope.'
```

### Event-driven scan

Later triggers:

- issue created
- issue moved into sprint
- issue blocked
- issue stale threshold reached
- PR linked to issue

These can enqueue scoped analysis rather than running the whole board scan.

## Human-In-The-Loop

Use a local approval inbox first.

### Phase 1: ApprovalRequest records

Each proposed Jira mutation becomes an approval record.

```yaml
apiVersion: jira-hygiene.agent-platform.local/v1alpha1
kind: JiraApprovalRequest
metadata:
  name: platform-123-label-component-update
  namespace: jira-hygiene
spec:
  issue: PLATFORM-123
  summary: Add component and hygiene label
  risk: low
  proposed_by: jira-hygiene-orchestrator-agent
  actions:
    - type: add_label
      label: hygiene/type-platform-support
    - type: set_component
      component: developer-experience
  status: pending
```

Approval:

```sh
kubectl patch jiraapprovalrequest platform-123-label-component-update \
  -n jira-hygiene \
  --type merge \
  -p '{"spec":{"status":"approved","approved_by":"chris"}}'
```

The executor only applies approved requests.

### Phase 2: GitHub digest approval

For local development, the agent can open a GitHub issue containing the hygiene digest. A human applies a label:

```text
jira-hygiene-approved
```

The executor then applies only the proposed updates referenced in the approved digest.

### Phase 3: Microsoft Teams

Teams can be added as a notification and approval surface later.

Possible patterns:

- Teams incoming webhook posts digest only
- Power Automate updates `JiraApprovalRequest`
- Bot Framework approve/reject buttons
- internal Teams MCP server if one exists

Teams should not be the approval source of truth. Approval records should live in Kubernetes or another auditable backend.

## Tooling

### Required MCP tools

Initial real tools:

- `jira.search_issues`
- `jira.get_issue`
- `jira.get_comments`
- `jira.find_related`
- `jira.add_label_propose`
- `jira.update_component_propose`
- `jira.assign_issue_propose`
- `jira.add_comment_propose`
- `repo.lookup_codeowners`
- `github.get_linked_prs`
- `approval.create_request`
- `approval.list_pending`
- `approval.execute_approved`

The first implementation can use propose tools that only create approval records. A separate executor handles writes.

### Tool safety levels

```yaml
tools:
  jira.search_issues:
    risk: read
  jira.get_issue:
    risk: read
  jira.get_comments:
    risk: read
  jira.add_label:
    risk: write_requires_approval
  jira.assign_issue:
    risk: write_requires_approval
  jira.transition_issue:
    risk: write_requires_approval
  jira.add_comment:
    risk: write_requires_approval
```

## Data Model

### HygieneFinding

```yaml
finding_id: string
issue: string
scope_id: string
severity: low | medium | high
category: stale | missing_owner | missing_acceptance_criteria | duplicate | priority_mismatch | blocked
summary: string
evidence: []
first_seen: string
last_seen: string
dedupe_key: string
```

### ProposedJiraUpdate

```yaml
proposal_id: string
issue: string
reason: string
risk: low | medium | high
actions:
  - type: add_label
    value: hygiene/missing-acceptance-criteria
requires_approval: true
status: proposed | approved | rejected | executed | failed
```

### HygieneDigest

```yaml
run_id: string
scope_id: string
issues_scanned: integer
findings: []
proposals: []
summary_markdown: string
```

## Namespaces

Use a dedicated namespace:

```text
jira-hygiene
```

Suggested resources:

```text
jira-hygiene-config ConfigMap
jira-hygiene-orchestrator-agent Agent
jira-classifier-agent Agent
duplicate-detector-agent Agent
acceptance-criteria-agent Agent
ownership-agent Agent
priority-review-agent Agent
hygiene-digest-agent Agent
jira-hygiene-wakeup CronJob
jira-api-token Secret
approval inbox resources
```

## First Implementation Slice

Build the smallest real version:

1. Add `jira-hygiene` namespace.
2. Add `JiraHygieneConfig` as a ConfigMap.
3. Build a Jira MCP server or adapter with read-only tools first.
4. Add declarative specialist agents for classification and acceptance criteria.
5. Add an orchestrator agent that runs a propose-only scan.
6. Store findings as Kubernetes records or local SQLite/Postgres rows.
7. Create approval records for proposed Jira updates.
8. Add an executor that only applies approved updates.
9. Add a CronJob to wake the orchestrator every 12 hours.

## Local Development Strategy

The sample should support two operating modes:

### Real Jira mode

Uses a real Jira API token stored in Kubernetes Secret.

This mode can read configured Jira projects and create approval records. Writes stay disabled until explicitly enabled.

### Dry-run write mode

Reads from real Jira but does not write to Jira. Proposed writes are stored locally.

This is the safest default.

## Open Questions

- Should the Jira integration be a custom FastMCP server or an existing Jira MCP server?
- Should proposed updates be grouped by issue, by scope, or by run?
- Should approvals happen per issue or per digest?
- What is the right stale threshold per project type?
- Should the system use semantic duplicate detection with embeddings, or start with JQL and keyword matching?
- Where should findings history live before Langfuse or another trace store is added?

## Recommended Starting Decisions

- Start with dry-run write mode.
- Use real Jira read APIs once credentials are available.
- Use a custom FastMCP Jira adapter if existing MCP servers do not give the right propose-only safety model.
- Use one global CronJob for the first version.
- Use approval records as the source of truth.
- Keep Teams as a later notification adapter.

