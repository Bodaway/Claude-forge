# Workflow Guardian v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the workflow-guardian skill as a single portable SKILL.md that dynamically reads workflow.md, detects actionable checklist items via pattern matching, and executes actions only after explicit developer confirmation.

**Architecture:** Single monolithic SKILL.md replacing the existing skill + references directory. The skill follows a 5-phase pipeline (LOCATE → LOAD → DETECT → WALK → EXECUTE). All pattern detection rules, tool references, and edge case handling are inlined for cross-project portability.

**Tech Stack:** Claude Code skill (Markdown), Jira MCP (Atlassian), Azure DevOps CLI (`az`), Git

**Spec:** `docs/superpowers/specs/2026-03-24-workflow-guardian-v2-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Rewrite | `~/.claude/skills/workflow-guardian/SKILL.md` | Full skill: frontmatter, 5-phase pipeline, pattern tables, degradation, edge cases, tool references |
| Delete | `~/.claude/skills/workflow-guardian/references/mcp-tool-mapping.md` | Content inlined into SKILL.md |
| Delete | `~/.claude/skills/workflow-guardian/references/` | Empty directory after file removal |

---

### Task 1: Write frontmatter and skill header

**Files:**
- Rewrite: `~/.claude/skills/workflow-guardian/SKILL.md` (lines 1-30 of existing file)

- [ ] **Step 1: Write the YAML frontmatter**

```markdown
---
name: workflow-guardian
description: >
  Interactive workflow assistant that guides developers through Git & Jira workflow.
  Reads workflow.md dynamically, walks checklists, detects actionable items via pattern matching,
  and executes actions (Jira, Azure DevOps, Git) only after explicit developer confirmation.
  Degrades gracefully when MCP tools are unavailable.
  Trigger: When user wants to move a Jira ticket to the next status, start working on a ticket,
  create a PR, deploy, or follow the team workflow.
  Keywords: workflow, ticket, transition, checklist, deploy, recette, PR, review, status,
  move ticket, hotfix, start ticket, what's next.
license: MIT
metadata:
  author: team
  version: "2.0"
---
```

- [ ] **Step 2: Write the title, summary, and "When to Use" section**

```markdown
# Workflow Guardian

Interactive assistant that enforces the team's Git & Jira workflow by guiding developers through
each status transition, verifying checklist items, and recording actions only after explicit user confirmation.

## When to Use

- User wants to transition a Jira ticket to the next status
- User starts working on a ticket (picking from backlog)
- User needs to create a PR for a ticket
- User wants to deploy to staging/recette/production
- User asks "what's next?" for a ticket
- User wants to check if a ticket is ready for the next step
- User needs to run a hotfix
```

- [ ] **Step 3: Verify** — Read the file, confirm frontmatter parses correctly (no YAML syntax errors).

---

### Task 2: Write Critical Rules section

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append after "When to Use")

- [ ] **Step 1: Write the Critical Rules**

These are the non-negotiable safety constraints that must appear early in the file so the AI agent sees them first.

```markdown
## Critical Rules

1. **NEVER auto-write without user confirmation** — Every write action (Jira comment, transition, PR creation, field update, git branch creation, git push) MUST be explicitly approved by the user before execution. Always show what will be written/executed and ask "Proceed? (yes/no)" before calling any write tool.
2. **NEVER transition a ticket without user confirmation** — Always present the full checklist summary and get explicit "yes" before transitioning.
3. **NEVER skip checklist items** — Every item must be addressed: confirmed by user, auto-checked, or explicitly skipped by user.
4. **Workflow source of truth is `workflow.md`** — Always read it fresh at the start of each session. Never rely on cached or memorized content.
5. **Read-only operations are free** — Fetching ticket info, checking branch status, listing PRs = no confirmation needed. Only state-modifying actions require confirmation.
6. **Pattern detection is a guide, not a mandate** — If the pattern engine can't classify an item, default to asking the user. Never silently skip an item because it doesn't match a pattern.
```

- [ ] **Step 2: Verify** — Read the section, confirm all 6 rules from the spec are present.

---

### Task 3: Write the 5-Phase Pipeline overview

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append after Critical Rules)

- [ ] **Step 1: Write the pipeline overview**

```markdown
## How It Works — 5-Phase Pipeline

```
1. LOCATE  →  2. LOAD  →  3. DETECT  →  4. WALK  →  5. EXECUTE
```

1. **LOCATE** — Find `workflow.md` in the project
2. **LOAD** — Parse YAML metadata, fetch ticket from Jira, determine target transition
3. **DETECT** — Find matching checklist section, classify each item (auto-check / user-judgment / actionable)
4. **WALK** — Present items to user, run auto-checks, ask for confirmations, offer actions
5. **EXECUTE** — Present summary, get final confirmation, transition ticket, record Jira comment
```

- [ ] **Step 2: Verify** — Confirm the overview matches the spec's architecture section.

---

### Task 4: Write Phase 1 (LOCATE)

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write Phase 1**

```markdown
## Phase 1: LOCATE — Find workflow.md

Search for `workflow.md` in the following locations, in order:

1. Project root (working directory)
2. `workflow/` subdirectory
3. `docs/` subdirectory
4. `.claude/` subdirectory

```
Tool: Read
  file_path: <project_root>/workflow.md
```

**Validation:** The found file must contain either a `## Checklists` heading or a YAML `statuses:` block to confirm it is a workflow document.

**If not found or invalid:** Tell the user: "No workflow.md found in this project. The workflow-guardian skill requires a workflow.md file to operate." and stop.
```

- [ ] **Step 2: Verify** — Confirm search order matches spec, validation step is present.

---

### Task 5: Write Phase 2 (LOAD)

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write Phase 2 — YAML parsing and ticket identification**

This is the longest phase. It covers:
- YAML metadata parsing (status list with id, name, jira_transition_id, owner)
- Note about mixed id types (integers and dot-notation — treat all as strings)
- Ticket key identification from user input (any `XXX-123` pattern)
- Jira ticket fetch (read-only, no confirmation)
- Graceful degradation if Jira MCP unavailable (ask user for current status)
- Owner check: if `owner: client` → inform dev no action needed, ask what else
- Target transition determination:
  - User specified → use it
  - One logical next step → suggest it
  - Multiple options → present from `jira_get_transitions` and ask
  - Non-linear transitions (Bloqué, En pause, Abandonné) always available

```markdown
## Phase 2: LOAD — Parse workflow and identify ticket

### Step 2.1: Parse YAML metadata

Extract the `statuses:` block from the YAML code fence in workflow.md. Each status has:
- `id` — status identifier (string: may be integer like `4` or dot-notation like `10.1`)
- `name` — full Jira status name (e.g., `"4. En cours (W)"`)
- `jira_transition_id` — the Jira transition ID (used for API calls)
- `owner` — who is responsible (`dev`, `reviewer`, `client`)

**If YAML block is absent:** Fall back to parsing markdown headings to extract status names. Pattern: `### <id>. <name>` or `### <id> <name>`.

### Step 2.2: Identify the ticket

Ask the user for the ticket key if not already provided. Accept any pattern matching `[A-Z]+-\d+` (e.g., `SCB-435`, `PROJ-123`).

### Step 2.3: Fetch ticket from Jira

```
Tool: mcp__atlassian__jira_get_issue
  issue_key: <TICKET_KEY>
  fields: "summary,status,assignee,description,labels,priority"
```

Display: ticket summary, current status, assignee.

**If Jira MCP is unavailable:** Ask the user to provide the current status name manually. Match it against the YAML statuses list.

### Step 2.4: Check status owner

Look up the current status in the YAML metadata. If `owner: client`:

> "This ticket is in **<status name>** — this is a client-owned status. No dev action is required. Would you like to check something else?"

If `owner: dev` or `owner: reviewer` → proceed to Step 2.5.

### Step 2.5: Determine target transition

Fetch available transitions from Jira:

```
Tool: mcp__atlassian__jira_get_transitions
  issue_key: <TICKET_KEY>
```

**Decision logic:**
- If user already specified a target status → validate it exists in the transitions list, use it
- If the workflow.md heading for the current status has a single `→` target → suggest it: "Next step is **<target>**. Proceed with this transition?"
- If multiple targets are available → present them and ask the user to choose
- Non-linear transitions (to Bloqué, En pause, Abandonné) are always listed by Jira — present them if the user asks

**Transition ID validation:** Compare the transition ID from `jira_get_transitions` against the YAML `jira_transition_id`. If they differ → trust Jira (live data), but warn: "Note: the transition ID in workflow.md differs from Jira. Using Jira's ID."

**Already in target status:** If the ticket is already in the requested target status → inform the user. Ask: "This ticket is already in **<status>**. Would you like to re-validate the checklist or skip?"
```

- [ ] **Step 2: Verify** — Confirm all sub-steps from spec Phase 2 are present: YAML parsing, mixed id types, ticket fetch, degradation, owner check, transition determination, mismatch handling, already-in-target edge case.

---

### Task 6: Write Phase 3 (DETECT)

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write Phase 3 — Heading classification algorithm**

```markdown
## Phase 3: DETECT — Find checklist and classify items

### Step 3.1: Find the matching section

Locate the section in workflow.md that corresponds to the current → target transition. Classify headings using these patterns:

| Heading format | Type | Behavior |
|----------------|------|----------|
| `### X. Status → Y. Status` | **Transition** | Extract from/to statuses, parse checklist items below |
| `### X. Status — Checklist de review` (or `—` heading with checklist items) | **Review section** | Has sub-headings and branching outcomes (Approuvé/Retour). Walk full checklist, then ask which outcome applies |
| `### X. Status — Attente ...` (or contains `aucune action dev requise`) | **Waiting state** | Inform user no dev action needed. This should have been caught in Phase 2 owner check |
| `### X. Status` (standalone, e.g., `13. Abandonné`) | **Terminal section** | Parse checklist if present, no "from" status required |
| `### X.1 Status / X.2 Status` | **Combined section** | Applies to multiple statuses, parse single checklist for both |

**For numbered lists** (e.g., hotfix process): Treat numbered steps (`1.`, `2.`, etc.) the same as checklist items. Each step is walked sequentially. For flows spanning multiple Jira statuses, offer to transition at each relevant step.

**For multi-line checklist items**: When a `- [ ]` item is followed by indented sub-lines (starting with `  -`), treat sub-lines as metadata for the parent item. Use this metadata when executing the action (e.g., PR title format, target branch from sub-items).

**For branching outcomes** (review section): Walk all prerequisite items first (Revue de code + Tests sub-sections), then present the Decision section. Ask the user: "Review outcome — Approved or Return?" Execute the corresponding path.
```

- [ ] **Step 2: Write the pattern detection tables**

Include all four tables from the spec:

1. **Auto-check patterns** (8 patterns) — read-only, run silently
2. **User-judgment patterns** (6 patterns + catch-all) — ask confirmation
3. **Actionable patterns** (14 patterns) — show command, wait for yes/no
4. **Safeguard patterns** (1 pattern) — warn and prevent

Plus the **pattern precedence rule**: auto-check first → if passes, report verified; if fails, fall through to actionable.

```markdown
### Step 3.2: Classify each checklist item

For each item, match its text against the pattern tables below. Apply **pattern precedence**: if an item matches both auto-check and actionable, run the auto-check first. If it passes → report as verified. If it fails → fall through to actionable (offer to create/fix).

#### Auto-check patterns (read-only, no confirmation needed)

| Pattern | Action |
|---------|--------|
| `branche.*créée depuis`, `branch.*from` | Run `git branch --show-current`, verify branch prefix matches expected type |
| `numéro de ticket.*branche`, `ticket.*branch name` | Parse current branch name for ticket key |
| `PR.*créée`, `Pull Request.*créée`, `PR.*exists` | Run `az repos pr list --source-branch <branch> --status active` |
| `PR.*approuvée`, `PR.*approved` | Run `az repos pr show --id <id> --query "reviewers[].vote"` |
| `build.*passe`, `build.*passes` | Check last pipeline run status or ask user |
| `conflit`, `conflict` | Run `git merge-base` check |
| `branche.*à jour`, `branch.*up to date` | Run `git log main..HEAD --oneline` |
| `mergée sur main`, `merged to main` | Check if branch is merged into main |

#### User-judgment patterns (ask confirmation)

| Pattern | Prompt |
|---------|--------|
| `code.*complet`, `respecte.*critères`, `lisible`, `maintenable` | "Is this done? (yes/no)" |
| `spécifications.*jour`, `specs.*up to date` | "Are the specs updated? (yes/no)" |
| `tests.*pertinents`, `failles de sécurité`, `régression` | "Can you confirm? (yes/no)" |
| `critères d'acceptation.*lus`, `lire les commentaires` | "Have you done this? (yes/no)" |
| `conventions.*équipe.*respectées` | "Are team conventions respected? (yes/no)" |
| `smoke test`, `test rapide`, `vérification fonctionnelle` | "Have you completed the smoke test? (yes/no)" |
| *(any unmatched item)* | Default: ask user to confirm or skip |

#### Actionable patterns (show command, wait for individual confirmation)

| Pattern | Proposed action |
|---------|-----------------|
| `branche.*créée depuis main`, `créer.*branche` | `git checkout main && git pull && git checkout -b <type>/<TICKET>-<desc>` |
| `Pull Request.*créée`, `PR.*créée sur Azure` | `az repos pr create --title "<TICKET> — <summary>" --source-branch <branch> --target-branch <target>` (target branch = `main` or `release/*` — determine from checklist sub-item metadata) |
| `PR.*assignée.*reviewer` | `az repos pr reviewer add --id <id> --reviewers <email>` (ask user for reviewer email) |
| `statut Jira.*passé` | `mcp__atlassian__jira_transition_issue` with transition_id from Phase 2 |
| `heures passées.*worklog` | `mcp__atlassian__jira_add_worklog` or remind user to log time manually |
| `commentaire.*ticket Jira`, `description.*PR.*commentaire` | `mcp__atlassian__jira_add_comment` with the PR description text |
| `supprimer la branche`, `delete.*branch` | `git push origin --delete <branch>` |
| `pipeline.*déploiement`, `déclencher.*pipeline` | `az pipelines run --name <pipeline>` (ask user for pipeline name) |
| `PO.*notifié`, `client.*notifié` | `mcp__atlassian__jira_add_comment` with notification message |
| `version.*créée dans Jira`, `plan de MEP` | Remind user: "Create a version in Jira and draft the MEP plan manually." |
| `réserves.*créées.*tickets`, `nouveaux tickets.*liés` | Offer to create linked tickets via `mcp__atlassian__jira_create_issue` + `mcp__atlassian__jira_create_issue_link` |
| `PR.*fermée`, `PR.*closed` | `az repos pr update --id <id> --status abandoned` |
| `dépendances.*liées`, `tickets.*liés` | Check via `mcp__atlassian__jira_get_issue` link fields, or remind user |
| `approbation.*PO.*formalisée` | Ask user: "Has PO approval been recorded on the ticket? (yes/no)" |

#### Safeguard patterns (warn and prevent)

| Pattern | Action |
|---------|--------|
| `Ne pas réouvrir l'ancienne branche`, `not reopen` | In correction flow (9 → 4): check if a branch for this ticket already exists (`git branch -r --list "*<TICKET>*"`). If found → **warn**: "An existing branch was found for this ticket: `<branch>`. Do NOT reuse it. Creating a new branch from main instead." Offer to create the new branch. |
```

- [ ] **Step 3: Verify** — Count patterns: 8 auto-check, 6+1 user-judgment, 14 actionable, 1 safeguard. Confirm pattern precedence rule is documented. Confirm multi-line and numbered list handling are present.

---

### Task 7: Write Phase 4 (WALK)

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write Phase 4**

```markdown
## Phase 4: WALK — Present items and collect confirmations

Walk through checklist items in groups:

### Auto-checks first

Run all auto-check items silently. Report results as a batch:

```
Auto-checks:
  [x] Branch exists: fix/SCB-435-date-offset ✓
  [x] Ticket key in branch name: SCB-435 ✓
  [x] PR exists: PR #142 (active) ✓
  [ ] PR approved: waiting (0/1 approvals) ✗ — BLOCKING
```

If a blocking auto-check fails → bold it and inform the user. Do not stop the walk — continue with other items, but flag it in the final summary.

### User-judgment items next

Present each item one at a time:

```
"Le code est complet et respecte les critères d'acceptation"
→ Is this done? (yes/no/skip)
```

If user says **skip** → mark as skipped with reason.

### Actionable items last

For each actionable item, show the exact command and wait:

```
I will run:
  az repos pr create --title "SCB-435 — Fix date offset" \
    --source-branch fix/SCB-435-date-offset \
    --target-branch main \
    --description "Fixes date offset issue. See SCB-435."

Proceed? (yes/no)
```

- **yes** → execute, report result
- **no** → mark as skipped by user, continue

### Safeguard items

If a safeguard pattern triggers, show the warning **before** offering the action:

```
⚠ WARNING: An existing branch was found: fix/SCB-435-old-attempt
Do NOT reuse it — risk of desynchronization with main.
I will create a NEW branch: fix/SCB-435-correction-v2

Proceed? (yes/no)
```

### Branching outcomes (review sections)

After walking all prerequisite items, present the decision:

```
All review items completed. What is the outcome?
  (A) Approved — PR is validated, proceed to next status
  (B) Return — Comments left on PR, ticket returns to "4. En cours (W)"
```

Execute the corresponding path based on user choice.
```

- [ ] **Step 2: Verify** — Confirm all 4 item types are covered: auto-check, user-judgment, actionable, safeguard. Confirm branching outcome handling is present.

---

### Task 8: Write Phase 5 (EXECUTE)

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write Phase 5 — Final summary and execution**

```markdown
## Phase 5: EXECUTE — Confirm and record

### Step 5.1: Present full summary

Once ALL items are walked, present the transition summary:

```
## Transition Summary: <FROM STATUS> → <TO STATUS>

Ticket: <KEY> — <SUMMARY>
Responsable: <ROLE from workflow.md>

  [x] Item 1 — verified automatically
  [x] Item 2 — confirmed by user
  [x] Item 3 — action taken (PR #142 created)
  [ ] Item 4 — skipped by user (reason)

I will:
1. Transition <KEY> to "<TARGET STATUS>" (transition_id: <ID>)
2. Add a Jira comment documenting this checklist

Proceed? (yes/no)
```

**Do NOT execute anything until the user explicitly says yes.**

### Step 5.2: Execute transition

```
Tool: mcp__atlassian__jira_transition_issue
  issue_key: <TICKET_KEY>
  transition_id: "<ID>"   # from jira_get_transitions, validated against YAML
```

### Step 5.3: Add Jira comment

```
Tool: mcp__atlassian__jira_add_comment
  issue_key: <TICKET_KEY>
  body: |
    ## Workflow Checklist — <FROM> → <TO>

    | # | Item | Status |
    |---|------|--------|
    | 1 | <item text> | Verified |
    | 2 | <item text> | Confirmed |
    | 3 | <item text> | Action taken: <detail> |
    | 4 | <item text> | Skipped: <reason> |

    Transitioned on <YYYY-MM-DD>
```

### Step 5.4: Confirm completion

After successful execution:

```
✅ <TICKET_KEY> transitioned to "<TARGET STATUS>"
```

**If Jira MCP is unavailable:** Instead of executing, show the user what to do:

```
Manual steps required:
1. In Jira, transition <KEY> to "<TARGET STATUS>"
2. Add a comment with the checklist summary above
```
```

- [ ] **Step 2: Verify** — Confirm the full confirmation protocol from the spec is present: summary, proceed gate, transition, comment, completion message, degradation.

---

### Task 9: Write Graceful Degradation section

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write the degradation section**

```markdown
## Graceful Degradation

At the start of the session, detect tool availability. For each unavailable tool, show one warning and adapt silently for the rest of the session.

### Detection

| Tool | How to detect |
|------|---------------|
| **Jira MCP** | Attempt `mcp__atlassian__jira_get_issue` — if tool not found or fails → unavailable |
| **Azure DevOps CLI** | Run `az repos pr list --top 1` via Bash — if `az` not found → unavailable |
| **Git** | Run `git status` via Bash — if not a git repo → unavailable |

### Notification (once per tool, at session start)

```
⚠ Jira MCP not available — I'll guide you through the checklist but you'll need to update Jira manually.
⚠ Azure DevOps CLI (`az`) not found — I'll show you the commands to run manually.
```

### Behavior matrix

| Tool missing | Auto-checks | Actionable items |
|---|---|---|
| **Jira MCP** | Ask user for current status manually | Show transition name + ID for manual update |
| **Azure DevOps CLI** | Can't verify PR existence/approval — ask user | Show `az` commands for user to copy-paste |
| **Git** | Can't verify branches/conflicts — ask user | Show git commands for user to copy-paste |
| **All missing** | Pure manual checklist — still walk every item, ask confirmation, show summary at end |
```

- [ ] **Step 2: Verify** — Confirm all 3 tools are covered, notification format matches spec, behavior matrix is complete.

---

### Task 10: Write Edge Cases section

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write edge cases**

```markdown
## Edge Cases

### Ticket already in target status
If the ticket is already in the requested target status → inform the user:
> "This ticket is already in **<status>**. Would you like to re-validate the checklist retroactively, or skip?"

### Non-linear transitions (Bloqué, En pause, Abandonné)
These are available from any status in Jira. When requested:
- Find the matching section in workflow.md
- Walk its checklist (no "from" status validation needed)

### Jira transition IDs mismatch
If `jira_get_transitions` returns different IDs than the YAML block → trust Jira (live data). Warn: "Note: transition ID in workflow.md differs from Jira — using Jira's ID. Consider updating workflow.md."

### Meta-instructions
When a checklist item describes a workflow path rather than a discrete action (e.g., "Reprendre le cycle normal : correction → review → merge → redéploiement recette"):
- Inform the user of the full path ahead
- Offer to start the first step only
- Do not attempt to automate the entire path in one go

### YAML block absent
If workflow.md has no YAML `statuses:` block, fall back to parsing markdown headings:
- Extract status names from `### <id>. <name>` patterns
- Transition IDs must come exclusively from `jira_get_transitions` (no YAML to reference)
- Owner information is not available — treat all statuses as dev-actionable
```

- [ ] **Step 2: Write the Portability section** (append after edge cases)

```markdown
## Portability

This skill is designed to be copied across projects. It makes no assumptions about project structure, team names, or tooling beyond what is described here.

- **Single file** — Everything is in this SKILL.md. No external references needed.
- **No hardcoded values** — No project keys, paths, team names, pipeline names, or reviewer emails. All values come from workflow.md or user input.
- **Ticket key format** — Detected from user input: any pattern matching `[A-Z]+-\d+`.
- **Branch prefixes** — Read from workflow.md "Types de branches" table. Do not assume `feat/`, `fix/`, etc. — parse the table for the actual prefixes used by the project.
- **Status names** — From workflow.md YAML block, validated live against Jira `get_transitions`.
- **PR tooling** — Assumes Azure DevOps (`az` CLI) for Pull Requests. If `az` is unavailable, degrades to showing commands for copy-paste. Future extension point: detect `gh` (GitHub CLI) or `glab` (GitLab CLI) as alternatives.
```

- [ ] **Step 3: Verify** — Confirm all 7 portability rules from the spec are present.

---

### Task 11: Write MCP Tool Reference (inlined)

**Files:**
- Modify: `~/.claude/skills/workflow-guardian/SKILL.md` (append)

- [ ] **Step 1: Write the inlined tool reference**

This replaces the old `references/mcp-tool-mapping.md` file. Keep it concise — just the tool names, key parameters, and important notes.

```markdown
## Tool Reference

### Jira MCP Tools

| Action | Tool | Key Parameters |
|--------|------|----------------|
| Get ticket | `mcp__atlassian__jira_get_issue` | `issue_key`, `fields` |
| Get transitions | `mcp__atlassian__jira_get_transitions` | `issue_key` |
| Transition ticket | `mcp__atlassian__jira_transition_issue` | `issue_key`, `transition_id`, `comment` |
| Add comment | `mcp__atlassian__jira_add_comment` | `issue_key`, `body` (Markdown) |
| Update fields | `mcp__atlassian__jira_update_issue` | `issue_key`, `fields` (JSON string) |
| Search tickets | `mcp__atlassian__jira_search` | `jql` |
| Create issue | `mcp__atlassian__jira_create_issue` | `project_key`, `issue_type`, `summary`, `description` |
| Link issues | `mcp__atlassian__jira_create_issue_link` | `type`, `inward_issue`, `outward_issue` |
| Add worklog | `mcp__atlassian__jira_add_worklog` | `issue_key`, `time_spent`, `comment` |
| Get sprint issues | `mcp__atlassian__jira_get_sprint_issues` | `sprint_id` — useful for batch/release workflows |

**Important:** `transition_id` is a string (e.g., `"7"`, `"16"`). Always call `get_transitions` first — never hardcode IDs.

### Azure DevOps CLI (via Bash)

| Action | Command |
|--------|---------|
| List PRs for branch | `az repos pr list --source-branch <branch> --status active` |
| Create PR | `az repos pr create --title "<title>" --description "<desc>" --source-branch <src> --target-branch <target>` |
| Show PR details | `az repos pr show --id <id>` |
| Check PR reviewers | `az repos pr show --id <id> --query "reviewers[].vote"` |
| Add reviewer | `az repos pr reviewer add --id <id> --reviewers <email>` |
| Close PR (abandon) | `az repos pr update --id <id> --status abandoned` |
| Run pipeline | `az pipelines run --name <pipeline-name>` |
| Check build | `az pipelines runs show --id <run-id>` |

### Git (via Bash)

| Action | Command |
|--------|---------|
| Current branch | `git branch --show-current` |
| Create branch | `git checkout main && git pull && git checkout -b <type>/<TICKET>-<desc>` |
| Check branch up to date | `git log main..HEAD --oneline` |
| Check for conflicts | `git merge-base --is-ancestor main HEAD` |
| Find existing branches for ticket | `git branch -r --list "*<TICKET>*"` |
| Delete remote branch | `git push origin --delete <branch>` |
| Push branch | `git push -u origin <branch>` |
```

- [ ] **Step 2: Verify** — Confirm all tools from old `mcp-tool-mapping.md` are present, plus new ones from the spec (create_issue, create_issue_link, add_worklog, close PR, find branches).

---

### Task 12: Delete old references directory

**Files:**
- Delete: `~/.claude/skills/workflow-guardian/references/mcp-tool-mapping.md`
- Delete: `~/.claude/skills/workflow-guardian/references/`

- [ ] **Step 1: Delete the old reference file and directory**

Run:
```bash
rm ~/.claude/skills/workflow-guardian/references/mcp-tool-mapping.md
rmdir ~/.claude/skills/workflow-guardian/references
```

- [ ] **Step 2: Verify** — Run `ls ~/.claude/skills/workflow-guardian/` and confirm only `SKILL.md` remains.

---

### Task 13: Smoke test — Run the skill against a real ticket

- [ ] **Step 1: Invoke the skill on a real ticket**

Pick any ticket in a known status from a project that uses the numbered workflow (e.g., SCB project). Find a suitable ticket at execution time:

```
/workflow-guardian <TICKET_KEY>
```

Verify:
- Phase 1: Finds `workflow.md` in `workflow/` subdirectory
- Phase 2: Parses YAML, fetches ticket, identifies status "0. Ouvert", suggests transition to "1. A chiffrer (W)"
- Phase 3: Finds the matching checklist section, classifies items
- Phase 4: Walks items, asks for confirmation
- Phase 5: Presents summary (do NOT actually execute — decline at the "Proceed?" gate)

- [ ] **Step 2: Test graceful degradation**

From a directory with no `az` CLI available, invoke the skill and verify:
- Warning message appears for Azure DevOps CLI
- Checklist walk still works with manual prompts
- Commands shown for copy-paste

- [ ] **Step 3: Test a review section**

Use a ticket in "5. A tester en interne (W)" status. Verify:
- The review checklist (Revue de code + Tests) is walked
- The branching outcome (Approuvé/Retour) is presented after prerequisites

---

### Task 14: Commit

- [ ] **Step 1: Stage and commit**

```bash
git add ~/.claude/skills/workflow-guardian/SKILL.md
git commit -m "feat: rewrite workflow-guardian skill v2

- Single monolithic SKILL.md for cross-project portability
- Dynamic workflow.md parsing (YAML metadata + heading classification)
- Pattern-based detection of auto-check, user-judgment, and actionable items
- Explicit confirmation required for all write actions
- Graceful degradation when Jira MCP / Azure DevOps CLI / Git unavailable
- Edge case handling: review branching, hotfix, non-linear transitions
- Inlined tool reference (replaces references/ directory)"
```

- [ ] **Step 2: Verify** — `git log -1` shows the commit, `git status` is clean.
