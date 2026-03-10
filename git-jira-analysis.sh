#!/bin/bash
# git-jira-analysis.sh
# Analyses consistency between Jira ticket statuses and Git/Azure DevOps PR states
#
# Usage: ./git-jira-analysis.sh <JIRA-PROJECT-KEY> [--sprint <sprint-name>] [--tickets TICKET-1,TICKET-2,...]
# Example: ./git-jira-analysis.sh PROJ
# Example: ./git-jira-analysis.sh PROJ --tickets PROJ-101,PROJ-102,PROJ-103
#
# Requirements:
#   - claude CLI installed (Claude Code)
#   - Jira and Azure DevOps MCP servers configured in user settings (~/.claude.json)
#   - Must be run from within the target git repository

set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────────────────
PROJECT_KEY="${1:-}"
SPRINT_NAME=""
TICKETS=""

if [ -z "$PROJECT_KEY" ]; then
    echo "Usage: $0 <JIRA-PROJECT-KEY> [--sprint <sprint-name>] [--tickets TICKET-1,TICKET-2,...]"
    echo ""
    echo "Examples:"
    echo "  $0 PROJ                                    # All active tickets in project"
    echo "  $0 PROJ --sprint 'Sprint 42'               # Tickets in a specific sprint"
    echo "  $0 PROJ --tickets PROJ-101,PROJ-102        # Specific tickets only"
    exit 1
fi

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sprint)
            SPRINT_NAME="${2:-}"
            if [ -z "$SPRINT_NAME" ]; then
                echo "Error: --sprint requires a value"
                exit 1
            fi
            shift 2
            ;;
        --tickets)
            TICKETS="${2:-}"
            if [ -z "$TICKETS" ]; then
                echo "Error: --tickets requires a comma-separated list"
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ── Precondition checks ─────────────────────────────────────────────────────────
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Must be run from within a git repository."
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

GLOBAL_MCP_CONFIG="${HOME}/.claude.json"
if [ ! -f "$GLOBAL_MCP_CONFIG" ]; then
    echo "Error: User Claude config not found at $GLOBAL_MCP_CONFIG"
    echo "Please configure Jira and Azure DevOps MCP servers via: claude mcp add"
    exit 1
fi

if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' CLI not found. Please install Claude Code."
    exit 1
fi

# ── Build ticket filter clause ──────────────────────────────────────────────────
TICKET_FILTER=""
if [ -n "$TICKETS" ]; then
    TICKET_FILTER="Only analyse the following tickets: ${TICKETS} (comma-separated list)."
elif [ -n "$SPRINT_NAME" ]; then
    TICKET_FILTER="Only analyse tickets belonging to sprint '${SPRINT_NAME}'."
else
    TICKET_FILTER="Analyse all tickets in project ${PROJECT_KEY} that are NOT in terminal states (13. ABANDONNÉ or 14. CLOS)."
fi

# ── Info banner ─────────────────────────────────────────────────────────────────
echo "=========================================="
echo " Git ↔ Jira Consistency Analysis"
echo "=========================================="
echo " Project : $PROJECT_KEY"
[ -n "$SPRINT_NAME" ] && echo " Sprint  : $SPRINT_NAME"
[ -n "$TICKETS" ]     && echo " Tickets : $TICKETS"
echo " Repo    : $REPO_ROOT"
echo "=========================================="
echo ""

# ── Build Claude prompt ─────────────────────────────────────────────────────────
PROMPT=$(cat <<'CLAUDE_PROMPT_HEADER'
You are an automated consistency auditor. Your task is to analyse Jira tickets and compare their statuses against the actual state of Git branches and Azure DevOps Pull Requests to detect inconsistencies.

Work carefully and methodically. Follow every step in order.

---

## Reference: Jira Workflow Statuses

The Jira workflow has these statuses (ordered by lifecycle stage):

| # | Status | Category |
|---|--------|----------|
| 0 | OUVERT | New |
| 1 | A CHIFFRER (W) | Pre-dev |
| 2 | A VALIDER (S) | Pre-dev |
| 3 | BACKLOG (W) | Ready |
| 4 | EN COURS (W) | Active dev |
| 5 | A TESTER EN INTERNE (W) | Internal test |
| 6 | A DÉPLOYER EN RECETTE (W) | Deploy to staging |
| 7 | A RECETTER (W) | Staging test |
| 8 | A RECETTER (S) | Client staging test |
| 9 | A CORRIGER (W) | Fix after staging |
| 10.1 | A DÉPLOYER EN PRODUCTION (W) | Deploy to prod |
| 10.2 | A DÉPLOYER EN PRODUCTION AVEC RÉ... (W) | Deploy to prod with regression |
| 12.1 | BLOQUÉ | Blocked |
| 12.2 | EN PAUSE | Paused |
| 13 | ABANDONNÉ | Abandoned (terminal) |
| 14 | CLOS | Closed (terminal) |

Statuses marked (W) concern the dev team. Statuses marked (S) concern the client.

---

## Consistency Rules

For each Jira ticket, apply these rules based on its current status:

### Rule 1 — Active development statuses (4, 5, 9): PR must be OPEN
If the ticket is in status **4 (EN COURS)**, **5 (A TESTER EN INTERNE)**, or **9 (A CORRIGER)**:
- There MUST be at least one open (not merged, not abandoned) Pull Request in Azure DevOps whose branch name or title references this ticket ID.
- **Violation:** "Ticket {ID} is in status '{status}' but no open PR was found."

### Rule 2 — Post-staging statuses (7, 8, 9, 10.1, 10.2): PR must be MERGED
If the ticket is in status **7 (A RECETTER)**, **8 (A RECETTER S)**, **10.1 (A DÉPLOYER EN PRODUCTION)**, or **10.2 (A DÉPLOYER EN PRODUCTION AVEC RÉ...)**:
- There MUST be at least one merged/completed Pull Request in Azure DevOps referencing this ticket ID.
- **Violation:** "Ticket {ID} is in status '{status}' but no merged PR was found."

### Rule 3 — Status 9 (A CORRIGER) special: both rules apply
Status 9 means the developer must fix issues found during staging. Therefore:
- Rule 2 applies: there must be at least one previously merged PR (the original work).
- Rule 1 applies: there must ALSO be a NEW open PR for the correction work.
- **Violation (if no open PR):** "Ticket {ID} is in A CORRIGER but no open correction PR was found."
- **Violation (if no merged PR):** "Ticket {ID} is in A CORRIGER but no previously merged PR exists."

### Rule 4 — Pre-development statuses (0, 1, 2, 3): no PR expected
If the ticket is in status **0, 1, 2, or 3**:
- There should be NO open PR for this ticket. If one exists, it may indicate the Jira status was not updated.
- **Warning:** "Ticket {ID} is in status '{status}' (pre-dev) but an open PR was found — status may need updating."

### Rule 5 — Terminal statuses (13, 14): PR should be merged or abandoned
If the ticket is in status **13 (ABANDONNÉ)** or **14 (CLOS)**:
- Any associated PR should be either merged (completed) or abandoned. No PR should remain open.
- **Warning:** "Ticket {ID} is closed/abandoned but has an open PR that should be closed."

### Rule 6 — Blocked/Paused (12.1, 12.2): informational
If the ticket is in **12.1 (BLOQUÉ)** or **12.2 (EN PAUSE)**:
- Flag these for visibility but do not raise violations.
- **Info:** "Ticket {ID} is {BLOQUÉ/EN PAUSE} — review if this is still accurate."

---

## Output Format

Produce a structured report with these sections:

### 1. Summary
- Total tickets analysed
- Number of violations found
- Number of warnings found

### 2. Violations (blocking inconsistencies)
For each violation:
- **Ticket ID** — Jira status — Rule violated — Description
- Sorted by severity (Rule 3 first, then Rule 1, then Rule 2, then Rule 5)

### 3. Warnings (non-blocking but worth reviewing)
For each warning:
- **Ticket ID** — Jira status — Rule — Description

### 4. Info
- Blocked/paused tickets
- Any tickets where the PR title or branch does not match the ticket ID pattern

### 5. Clean tickets
- List of tickets where everything is consistent (just the IDs, one line)

---

CLAUDE_PROMPT_HEADER
)

# Append the dynamic part
PROMPT="${PROMPT}
## Your Task

Project key: **${PROJECT_KEY}**
${TICKET_FILTER}

### Step 1 — Collect Jira Tickets

Use the Jira MCP tools to search for tickets in project **${PROJECT_KEY}**.
${TICKET_FILTER}
For each ticket, record: ticket ID, current status name, status number, and summary/title.

### Step 2 — Collect Azure DevOps PRs

Use the Azure DevOps MCP tools to list all Pull Requests (open, completed, and abandoned) in the repository.
For each PR, record: PR ID, title, source branch, status (active/completed/abandoned), and target branch.

### Step 3 — Match and Analyse

For each Jira ticket collected in Step 1:
1. Search for associated PRs by matching the ticket ID in the PR title or source branch name.
2. Determine which consistency rules apply based on the ticket's current Jira status.
3. Check each applicable rule and record any violations or warnings.

### Step 4 — Generate Report

Output the structured report as described in the Output Format section above.
Use markdown formatting. Be precise and factual — only report actual findings.

---

Work methodically. Do not skip any step.
"

# ── Invoke Claude ────────────────────────────────────────────────────────────────
echo "Starting consistency analysis..."
echo ""

claude \
    --dangerouslySkipPermissions \
    -p "$PROMPT"

echo ""
echo "=========================================="
echo " Analysis complete for: $PROJECT_KEY"
echo "=========================================="
