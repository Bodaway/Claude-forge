# Workflow Guardian v2 — Design Spec

**Date:** 2026-03-24
**Status:** Approved
**Scope:** Rewrite of the existing `workflow-guardian` skill

---

## Summary

Rewrite the workflow-guardian skill as a single, portable, monolithic `SKILL.md` that:

- Reads `workflow.md` dynamically (never hardcodes workflow details)
- Parses YAML metadata block for status mapping and transition IDs
- Detects actionable checklist items via text pattern matching
- Executes actions (Jira, Azure DevOps, Git) only after explicit developer confirmation
- Degrades gracefully when MCP tools or CLI are unavailable
- Is fully project-agnostic — copy-paste across any project with a `workflow.md`

---

## Decisions from Brainstorming

| Question | Decision |
|----------|----------|
| Replace or improve existing skill? | **Replace** — full rewrite |
| Generic vs. smart detection? | **Generic with smart detection** — parse workflow.md dynamically, detect actionable items via patterns |
| How to locate workflow.md? | **Search** — project root, then `workflow/`, `docs/`, `.claude/` |
| Use YAML metadata block? | **Yes with live validation** — YAML for structure, `jira_get_transitions` for runtime truth |
| Automation level? | **Mixed** — read ops silent, write ops require individual confirmation |
| When MCP unavailable? | **Degrade gracefully** — show commands for user to run manually |
| File structure? | **Single monolithic SKILL.md** — portable, one file copy-paste |

---

## Architecture: 5-Phase Pipeline

```
1. LOCATE  →  2. LOAD  →  3. DETECT  →  4. WALK  →  5. EXECUTE
```

### Phase 1: LOCATE

Search for `workflow.md` in order:
1. Project root
2. `workflow/`
3. `docs/`
4. `.claude/`

Validate the found file contains a workflow (check for `## Checklists` or the YAML `statuses:` block). If ambiguous match → tell user and stop.

### Phase 2: LOAD

1. Read `workflow.md`
2. Parse YAML metadata block → extract statuses (id, name, jira_transition_id, owner)
   - Note: `id` values may be integers (e.g., `0`, `4`) or dot-notation (e.g., `10.1`, `12.2`) — treat all as strings for matching
3. Ask user for ticket key if not provided
4. Fetch ticket from Jira via `mcp__atlassian__jira_get_issue` (read-only, no confirmation)
5. If Jira MCP unavailable → ask user for current status manually
6. Check status owner from YAML:
   - If `owner: client` → inform developer this is a client-owned status, no dev action needed. Ask if they want to check anything else.
   - If `owner: dev` or `owner: reviewer` → proceed
7. Determine current status and target transition:
   - If user specified target → use it
   - If only one logical next step → suggest it
   - Otherwise → present available transitions from `jira_get_transitions` and ask
   - Non-linear transitions (to Bloqué, En pause, Abandonné) are always available — present them if user asks

### Phase 3: DETECT

1. Find matching section in workflow.md by classifying the heading format:

   **Heading classification algorithm:**
   - `### X. Status → Y. Status` → **Transition**: extract from/to, parse checklist items
   - `### X. Status — Checklist de review` (or similar `—` heading with checklist items) → **Review section**: has sub-headings and branching outcomes (Approuvé/Retour). Walk the full checklist, then ask which outcome applies
   - `### X. Status — Attente ...` (or `aucune action dev requise`) → **Waiting state**: inform user no dev action needed
   - `### X. Status` (standalone, e.g., `13. Abandonné`) → **Terminal/standalone section**: parse checklist if present
   - `### X.1 Status / X.2 Status` → **Combined section**: applies to multiple statuses, parse checklist

2. Handle **multi-line checklist items**: when a `- [ ]` item is followed by indented sub-lines (starting with `  -`), treat sub-lines as metadata for the parent item (e.g., PR title format, target branch). Use this metadata when executing the parent action.

3. Handle **numbered lists** (hotfix section and similar): treat numbered steps the same as checklist items — classify and walk them. Each step is executed sequentially. For flows that span multiple Jira statuses (e.g., hotfix goes through En cours → A tester → production), offer to transition at each relevant step rather than treating it as a single jump.

4. Handle **branching outcomes** (review section): when a checklist contains mutually exclusive outcomes (e.g., "Approuvé" vs "Retour"), walk all prerequisite items first, then ask the user which outcome applies. Execute the corresponding transition.

5. Classify each checklist item into 3 categories via text pattern matching:
   - **Auto-check** (read-only)
   - **User-judgment** (ask confirmation)
   - **Actionable** (show command, wait for individual yes/no)

6. **Pattern precedence**: when an item matches both auto-check and actionable patterns, check auto-check first. If the check passes (e.g., PR already exists), report it as verified. If it fails (e.g., PR doesn't exist yet), fall through to actionable (offer to create it).

### Phase 4: WALK

Walk items one group at a time:
- **Auto-checks** → run silently, report results
- **User-judgment** → ask confirmation for each
- **Actionable** → show exact command/call, wait for individual "yes/no"

### Phase 5: EXECUTE

1. Present full summary with all items checked/confirmed
2. Wait for final "Proceed?" confirmation
3. Execute transition + add Jira comment documenting the checklist
4. If Jira MCP unavailable → show what user should do manually

---

## Pattern Detection Rules

### Auto-check patterns (read-only, no confirmation needed)

| Pattern in checklist text | Action |
|---|---|
| `branche.*créée depuis`, `branch.*from` | `git branch --show-current`, verify prefix |
| `numéro de ticket.*branche`, `ticket.*branch name` | Parse branch name for ticket key |
| `PR.*créée`, `Pull Request.*créée`, `PR.*exists` | `az repos pr list --source-branch <branch>` |
| `PR.*approuvée`, `PR.*approved` | `az repos pr show --id <id> --query "reviewers[].vote"` |
| `build.*passe`, `build.*passes` | Check last pipeline run or ask user |
| `conflit`, `conflict` | `git merge-base` check |
| `branche.*à jour`, `branch.*up to date` | `git log main..HEAD` |
| `mergée sur main`, `merged to main` | Check branch merge status |

### User-judgment patterns (ask confirmation)

| Pattern in checklist text | Behavior |
|---|---|
| `code.*complet`, `respecte.*critères`, `lisible`, `maintenable` | Ask: "Is this done? (yes/no)" |
| `spécifications.*jour`, `specs.*up to date` | Ask: "Are specs updated? (yes/no)" |
| `tests.*pertinents`, `failles de sécurité`, `régression` | Ask: "Can you confirm? (yes/no)" |
| `critères d'acceptation.*lus`, `lire les commentaires` | Ask: "Have you done this? (yes/no)" |
| `conventions.*équipe.*respectées`, `conventions.*respected` | Ask: "Are team conventions respected? (yes/no)" |
| `smoke test`, `test rapide`, `vérification fonctionnelle` | Ask: "Have you completed the smoke test? (yes/no)" |
| Any unmatched item | Default: ask user |

### Actionable patterns (show command, wait for individual confirmation)

| Pattern in checklist text | Proposed action |
|---|---|
| `branche.*créée depuis main`, `créer.*branche` | `git checkout main && git pull && git checkout -b <type>/<TICKET>-<desc>` |
| `Pull Request.*créée`, `PR.*créée sur Azure` | `az repos pr create --title "<TICKET> — <summary>" ...` |
| `PR.*assignée.*reviewer` | `az repos pr reviewer add --id <id> --reviewers <email>` |
| `statut Jira.*passé` | `mcp__atlassian__jira_transition_issue` |
| `heures passées.*worklog` | `mcp__atlassian__jira_add_worklog` or remind user |
| `commentaire.*ticket Jira`, `description.*PR.*commentaire` | `mcp__atlassian__jira_add_comment` |
| `supprimer la branche`, `delete.*branch` | `git push origin --delete <branch>` |
| `pipeline.*déploiement`, `déclencher.*pipeline` | `az pipelines run --name <pipeline>` |
| `PO.*notifié`, `client.*notifié` | Add Jira comment notifying stakeholder |
| `version.*créée dans Jira`, `plan de MEP` | Remind user to create version in Jira (manual) |
| `réserves.*créées.*tickets`, `nouveaux tickets.*liés` | Offer: `mcp__atlassian__jira_create_issue` + link |
| `PR.*fermée`, `PR.*closed` | Offer: `az repos pr update --id <id> --status abandoned` |
| `dépendances.*liées`, `tickets.*liés` | Auto-check via `mcp__atlassian__jira_get_issue` link fields, or remind user |
| `approbation.*PO.*formalisée` | Ask user to confirm PO approval is recorded on ticket |

### Safeguard patterns (warn and prevent)

| Pattern in checklist text | Action |
|---|---|
| `Ne pas réouvrir l'ancienne branche`, `not reopen` | When in correction flow (9 → 4): check if a branch for this ticket already exists. If yes, **warn** the user not to reuse it and offer to create a new one. |

---

## Graceful Degradation

### Detection at startup

| Tool | Detection method |
|---|---|
| Jira MCP | Attempt `mcp__atlassian__jira_get_issue` on the ticket |
| Azure DevOps CLI | Run `az repos pr list --top 1` |
| Git | Run `git status` |

### Behavior when unavailable

| Tool missing | Auto-checks | Actionable items |
|---|---|---|
| **Jira MCP** | Ask user for current status | Show transition ID + status name for manual update |
| **Azure DevOps CLI** | Can't check PR existence/approval | Show `az` commands for copy-paste |
| **Git** | Can't verify branches/conflicts | Show git commands for copy-paste |
| **All missing** | Pure manual checklist — walk every item, ask confirmation, show summary |

### Notification

One message at session start per unavailable tool:
```
Warning: Jira MCP not available — I'll guide you through the checklist but you'll need to update Jira manually.
```

No repeated warnings.

---

## Confirmation Protocol

### Individual write action

```
I will run:
  az repos pr create --title "SCB-435 — Fix date offset" --source-branch fix/SCB-435-date-offset --target-branch main

Proceed? (yes/no)
```

If no → skip, mark as "skipped by user", continue.

### Final transition confirmation

```
## Transition Summary: 4. En cours (W) → 5. A tester en interne (W)

Ticket: SCB-435 — Fix date offset
Responsable: Développeur assigné

  [x] Code complet — confirmed
  [x] Tests passent — confirmed
  [x] Build passe — confirmed
  [x] Ticket dans branche — verified (fix/SCB-435-date-offset)
  [x] Specs à jour — confirmed
  [x] PR créée — created (PR #142)
  [x] PR assignée — assigned (john@team.com)
  [ ] Worklog — skipped by user

I will:
1. Transition SCB-435 to "5. A tester en interne (W)" (transition_id: 7)
2. Add a Jira comment documenting this checklist

Proceed? (yes/no)
```

### Jira comment format

```markdown
## Workflow Checklist — 4. En cours (W) → 5. A tester en interne (W)

| # | Item | Status |
|---|------|--------|
| 1 | Code complet | Confirmed |
| 2 | Tests passent | Confirmed |
| 3 | Build passe | Confirmed |
| 4 | Ticket dans branche | Verified (fix/SCB-435-date-offset) |
| 5 | Specs à jour | Confirmed |
| 6 | PR créée | PR #142 |
| 7 | PR assignée | john@team.com |
| 8 | Worklog | Skipped |

Transitioned on 2026-03-24
```

---

## Portability Rules

- **Single file:** everything in `SKILL.md`, no external references
- **No hardcoded values:** no project keys, paths, team names, pipeline names, reviewer emails
- **Ticket key format:** detected from user input (any `XXX-123` pattern)
- **Branch prefixes:** read from workflow.md "Types de branches" table
- **Status names:** from workflow.md YAML block, validated live against Jira
- **YAML fallback:** if YAML block absent, fall back to parsing markdown headings
- **Assumes Azure DevOps** for PRs (via `az` CLI). If unavailable, degrades to showing commands for copy-paste. Future extension point: detect `gh` (GitHub) or `glab` (GitLab) as alternatives

---

## File Structure

```
~/.claude/skills/workflow-guardian/
└── SKILL.md
```

No references/ directory. Everything inlined for single-file portability.

---

## Edge Cases

### Ticket already in target status
If the ticket is already in the requested target status → inform the user, ask if they want to re-validate the checklist retroactively or skip.

### Non-linear transitions (Bloqué, En pause, Abandonné)
These are available from any status in Jira. When the user requests one:
- Find the matching section in workflow.md (e.g., `12.1 Bloqué / 12.2 En pause`)
- Walk its checklist
- No "from" status validation — these are always valid

### Jira transition IDs mismatch
If `jira_get_transitions` returns different IDs than the YAML block → trust Jira (live), but warn the user that workflow.md may be outdated.

### Meta-instructions ("Reprendre le cycle normal")
When a checklist item describes a workflow path rather than a discrete action (e.g., "Reprendre le cycle normal : correction → review → merge → redéploiement recette") → inform the user of the next steps but don't try to automate the entire path. Offer to start the first step.

---

## Critical Rules (carried forward)

1. **NEVER auto-write without user confirmation** — every write action requires explicit "yes"
2. **NEVER transition without user confirmation** — full summary + "Proceed?" gate
3. **NEVER skip checklist items** — every item must be addressed (confirmed, auto-checked, or explicitly skipped)
4. **Workflow source of truth is `workflow.md`** — always read fresh, never cache
5. **Read-only is free** — fetching ticket info, checking branch status = no confirmation needed
