# Gloo-Powered Automation PoCs for OpenCode

Date: 2026-04-27
Status: Draft plan
Scope: End-to-end proof-of-concept automations that use the `glooai/opencode` fork as the execution harness, with Gloo AI as the default model provider.

## Goal

Identify a small set of meaningful, reduced-scope automations that prove three things:

1. OpenCode can be used headlessly, not just as a local coding TUI.
2. Gloo AI can reliably power agentic workflows through the OpenCode runtime.
3. The same harness can run locally via cron/system services and later move to a cloud runner with minimal redesign.

## What This Fork Already Gives Us

The current fork already has the right primitives for automation:

- `gloocode` install/bootstrap flow for Gloo credentials and default provider behavior
- `opencode run` for non-interactive execution
- `opencode serve` plus HTTP API for long-lived agent backends
- JS SDK for programmatic session creation and prompt execution
- built-in agents, subagents, permissions, and MCP support

This means the PoCs should focus on orchestration around OpenCode, not inventing a second agent framework.

## Recommendation

Start with two PoCs:

1. **Nightly Repo Steward**
2. **Support Triage and Fix Router**

Add a third only if one of the first two proves stable:

3. **CI Failure Shepherd**

These cover the most interesting spread:

- scheduled local automation
- cloud-hosted/event-driven automation
- read-only analysis first, then controlled write actions

## PoC 1: Nightly Repo Steward

### Purpose

Run OpenCode on a schedule against one or more target repositories and produce a useful engineering artifact each night without requiring a human to sit in the loop.

### Reduced Test Case

Every night, for a configured list of repositories:

- fetch the latest `dev` or `main`
- inspect recent commits, open TODOs, failing tests, or stale local docs
- generate a structured summary with:
  - notable changes
  - likely risks
  - recommended next actions
  - optional low-risk doc or config cleanup candidates
- write the result to Markdown and optionally open a draft issue or draft PR

### Why It Matters

This proves OpenCode can act as a scheduled repo operator, not just a code editor. It also tests whether Gloo-backed prompts are consistent enough for unattended nightly work.

### Why OpenCode Is the Right Harness

- It already knows how to inspect a repo with tools instead of relying on raw prompt text.
- `opencode run` can cover a very small first version.
- `opencode serve` plus the SDK can support a more durable version with session history and structured outputs.

### Suggested Execution Shape

Phase 1:

- host: local machine or small VM
- trigger: cron or `launchd`/systemd timer
- runtime: `gloocode run` or SDK wrapper
- output: Markdown report in a central directory

Phase 2:

- promote to long-lived `opencode serve`
- use SDK to create one session per repo
- request structured JSON output
- publish to GitHub issue, Slack summary, or email digest

### Inputs

- repo path or clone URL
- branch to inspect
- task prompt template
- output target

### Outputs

- nightly Markdown report
- optional GitHub draft issue
- optional draft PR for narrowly scoped documentation/config changes

### Guardrails

- start read-only
- allow file edits only for docs/config cleanup in explicitly allowed repos
- require draft PRs, never direct pushes to protected branches

### Success Criteria

- runs unattended for 5 consecutive nights
- produces summaries that a maintainer considers useful at least 3 out of 5 times
- no unsafe or noisy write actions

## PoC 2: Support Triage and Fix Router

### Purpose

Use OpenCode as the agent that turns incoming support traffic into repo-aware engineering work products.

### Reduced Test Case

On a schedule or webhook trigger:

- pull new support items from a Slack channel, email inbox, or ticket export
- classify each item
  - bug
  - question
  - feature request
  - unclear / needs human follow-up
- map the issue to the most likely repo
- inspect the relevant codebase and docs
- produce one of:
  - a draft GitHub issue with repro and impacted area
  - a support reply draft
  - a small implementation plan if the request looks actionable

### Why It Matters

This is more interesting than generic “AI coding” because it connects external operational inputs to actual repository reasoning. It also fits Gloo’s real environment, where support and product requests span multiple repos.

### Why OpenCode Is the Right Harness

- its repo tools let the agent inspect the likely code area before answering
- MCP support can later bring Slack/GitHub/Jira into the same runtime
- server mode makes cloud hosting straightforward

### Suggested Execution Shape

Phase 1:

- host: cloud worker, container job, or small always-on service
- trigger: hourly poll or webhook
- runtime: `opencode serve` + JS SDK
- output: GitHub issue draft or Markdown triage artifact

Phase 2:

- add a second workflow for safe fix preparation
- for issues above a confidence threshold, create a feature branch and draft PR with only a plan or minimal repro artifact

### Inputs

- support message text
- attached logs or links
- repo routing rules
- prompt template for triage

### Outputs

- structured classification
- impacted repo guess with confidence
- draft issue or reply
- optional implementation plan

### Guardrails

- no autonomous code changes in v1
- require confidence threshold before repo routing
- route ambiguous cases to a human-review queue

### Success Criteria

- correctly routes a majority of sampled issues
- reduces manual triage time
- produces issue drafts that need only light editing

## Optional PoC 3: CI Failure Shepherd

### Purpose

Use OpenCode to investigate failing CI runs and produce a reviewer-friendly diagnosis.

### Reduced Test Case

When CI fails on a target repo:

- fetch workflow/job logs
- inspect changed files
- identify the likely failure cause
- produce:
  - a concise diagnosis
  - likely fix options
  - optional draft PR for mechanical fixes like workflow syntax or config drift

### Why It Is Third

This is valuable, but it depends on clean GitHub integration, log access, and better confidence around safe automated edits. It should follow the first two PoCs, not lead them.

## Architecture Direction

Use one orchestration pattern for all PoCs:

1. Scheduler or event source triggers a small runner.
2. Runner starts or connects to OpenCode.
3. OpenCode executes a scoped prompt against a target repo with Gloo as provider.
4. Structured output is persisted and optionally published to GitHub or Slack.
5. Any write action is isolated to a branch and surfaced as a draft artifact.

### Local-First Runner

Good for the first PoC:

- `cron`, `launchd`, or systemd timer
- `gloocode run` for the fastest path
- file-based outputs and optional GitHub publishing

### Cloud Runner

Good for the second and third PoCs:

- containerized `opencode serve`
- SDK client for session control
- webhook or queue consumer
- secret-managed Gloo credentials

## Implementation Plan

### Step 1: Prove Headless Execution

- verify `gloocode run` and/or SDK execution with Gloo defaults
- confirm structured output works for one canned repo analysis task
- capture required env vars and auth behavior

### Step 2: Build the Smallest Useful Runner

- create a tiny wrapper service or script outside or alongside OpenCode
- define a single prompt contract and JSON schema
- write outputs to local files first

### Step 3: Add Publishing

- GitHub draft issue creation for analysis outputs
- optional Slack digest or email summary

### Step 4: Add Controlled Write Actions

- branch creation only
- draft PRs only
- repo allowlist
- narrow task classes such as docs/config cleanup

## Suggested Order

1. Build **Nightly Repo Steward** first.
2. Build **Support Triage and Fix Router** second.
3. Build **CI Failure Shepherd** only after the first two produce stable, reviewable outputs.

## Why This Order

- PoC 1 is the simplest way to validate scheduled execution and prompt quality.
- PoC 2 proves business usefulness beyond coding assistance.
- PoC 3 has the highest integration and trust burden.

## Deliverables for the First Implementation Sprint

- one runner script or tiny service
- one prompt template
- one JSON schema for structured outputs
- one scheduled execution target
- one publication target such as GitHub issue drafts
- one short operator runbook

## Open Questions

- Should the first runner live inside `opencode`, in a sibling repo, or in an internal automation repo?
- Do we want to standardize on `opencode run` first, or go directly to `opencode serve` + SDK?
- Which repository should be the first safe target for nightly stewardship?
- Which support intake source should be the first triage source: Slack, email, or GitHub issues?

## Proposed Next Move

If this plan is accepted, the next implementation PR should build only **PoC 1: Nightly Repo Steward** with:

- one target repo
- read-only analysis
- structured JSON + Markdown output
- optional GitHub draft issue publication

That is the smallest end-to-end slice that meaningfully validates Gloo-powered automation through OpenCode.
