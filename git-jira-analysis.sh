#!/bin/bash
# git-jira-analysis.sh
# Analyses consistency between Jira ticket statuses and Git/Azure DevOps PR states
#
# Usage: ./git-jira-analysis.sh <JIRA-PROJECT-KEY> [options]
# Example: ./git-jira-analysis.sh PROJ
# Example: ./git-jira-analysis.sh PROJ --tickets PROJ-101,PROJ-102 --output report.md
#
# Options:
#   --sprint <name>         Filter by sprint name
#   --tickets <ID1,ID2,...> Analyse specific tickets only
#   --output <file>         Save report to file (in addition to stdout)
#   --json                  Output structured JSON instead of markdown
#   --verbose               Show progress during analysis
#
# Exit codes:
#   0  All tickets are consistent (no violations, no warnings)
#   1  Violations found (blocking inconsistencies)
#   2  Warnings found (non-blocking, but no violations)
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
OUTPUT_FILE=""
JSON_OUTPUT=false
VERBOSE=false

if [ -z "$PROJECT_KEY" ]; then
    echo "Usage: $0 <JIRA-PROJECT-KEY> [--sprint <name>] [--tickets ID1,ID2,...] [--output <file>] [--json] [--verbose]"
    echo ""
    echo "Examples:"
    echo "  $0 PROJ                                        # All active tickets in project"
    echo "  $0 PROJ --sprint 'Sprint 42'                   # Tickets in a specific sprint"
    echo "  $0 PROJ --tickets PROJ-101,PROJ-102            # Specific tickets only"
    echo "  $0 PROJ --output report.md                     # Save report to file"
    echo "  $0 PROJ --json                                 # JSON output for CI pipelines"
    echo "  $0 PROJ --verbose                              # Show progress"
    echo ""
    echo "Exit codes:"
    echo "  0  No issues found"
    echo "  1  Violations found (blocking)"
    echo "  2  Warnings only (non-blocking)"
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
        --output)
            OUTPUT_FILE="${2:-}"
            if [ -z "$OUTPUT_FILE" ]; then
                echo "Error: --output requires a file path"
                exit 1
            fi
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ── Precondition checks (shared) ────────────────────────────────────────────────
source "$(dirname "$0")/lib/preconditions.sh"

# ── Build ticket filter clause ──────────────────────────────────────────────────
TICKET_FILTER=""
if [ -n "$TICKETS" ]; then
    TICKET_FILTER="Only analyse the following tickets: ${TICKETS} (comma-separated list)."
elif [ -n "$SPRINT_NAME" ]; then
    TICKET_FILTER="Only analyse tickets belonging to sprint '${SPRINT_NAME}'."
else
    TICKET_FILTER="Analyse all tickets in project ${PROJECT_KEY} that are NOT in terminal states (13. ABANDONNÉ or 14. CLOS)."
fi

# ── Build output format instructions ────────────────────────────────────────────
OUTPUT_FORMAT_EXTRA=""
if [ "$JSON_OUTPUT" = true ]; then
    OUTPUT_FORMAT_EXTRA="
IMPORTANT: Output the report as a single valid JSON object (no markdown, no code fences) with this structure:
{
  \"summary\": { \"total\": N, \"violations\": N, \"warnings\": N },
  \"violations\": [ { \"ticket\": \"ID\", \"status\": \"...\", \"rule\": N, \"description\": \"...\" } ],
  \"warnings\": [ { \"ticket\": \"ID\", \"status\": \"...\", \"rule\": N, \"description\": \"...\" } ],
  \"info\": [ { \"ticket\": \"ID\", \"status\": \"...\", \"description\": \"...\" } ],
  \"clean\": [ \"ID1\", \"ID2\" ]
}
"
fi

VERBOSE_INSTRUCTIONS=""
if [ "$VERBOSE" = true ]; then
    VERBOSE_INSTRUCTIONS="
Before each step, print a short progress line to stderr prefixed with [PROGRESS], e.g.:
[PROGRESS] Fetching Jira tickets for project PROJ...
[PROGRESS] Found 24 tickets. Fetching Azure DevOps PRs...
[PROGRESS] Checking ticket PROJ-101 (status: EN COURS)...
"
fi

# ── Info banner ─────────────────────────────────────────────────────────────────
echo "==========================================" >&2
echo " Git ↔ Jira Consistency Analysis" >&2
echo "==========================================" >&2
echo " Project : $PROJECT_KEY" >&2
[ -n "$SPRINT_NAME" ] && echo " Sprint  : $SPRINT_NAME" >&2
[ -n "$TICKETS" ]     && echo " Tickets : $TICKETS" >&2
echo " Repo    : $REPO_ROOT" >&2
[ -n "$OUTPUT_FILE" ] && echo " Output  : $OUTPUT_FILE" >&2
[ "$JSON_OUTPUT" = true ] && echo " Format  : JSON" >&2
echo "==========================================" >&2
echo "" >&2

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

### Rule 2 — Post-staging statuses (7, 8, 10.1, 10.2): PR must be MERGED
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

### Rule 7 — Deploy to staging (6): transitional, no strict rule
If the ticket is in status **6 (A DÉPLOYER EN RECETTE)**:
- This is a transitional status. The PR may be open or recently merged.
- Do NOT raise a violation. Only raise a **Warning** if there is no PR at all (neither open nor merged):
  "Ticket {ID} is in A DÉPLOYER EN RECETTE but no PR (open or merged) was found."

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

At the very end of your output, on its own line, print exactly one of these tags (no other text on that line):
- **[EXIT:0]** if there are zero violations AND zero warnings
- **[EXIT:1]** if there is at least one violation
- **[EXIT:2]** if there are warnings but zero violations

---

CLAUDE_PROMPT_HEADER
)

# Append the dynamic part (needs variable expansion)
PROMPT="${PROMPT}
${OUTPUT_FORMAT_EXTRA}
${VERBOSE_INSTRUCTIONS}

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
Remember to include the [EXIT:N] tag on the last line.

---

Work methodically. Do not skip any step.
"

# ── Invoke Claude ────────────────────────────────────────────────────────────────
echo "Starting consistency analysis..." >&2
echo "" >&2

# Capture output to parse exit tag and optionally save to file
CLAUDE_OUTPUT=$(claude \
    --dangerouslySkipPermissions \
    -p "$PROMPT" 2>&2)

# Display the report
echo "$CLAUDE_OUTPUT"

# Save to file if requested
if [ -n "$OUTPUT_FILE" ]; then
    echo "$CLAUDE_OUTPUT" > "$OUTPUT_FILE"
    echo "" >&2
    echo "Report saved to: $OUTPUT_FILE" >&2
fi

echo "" >&2
echo "==========================================" >&2
echo " Analysis complete for: $PROJECT_KEY" >&2
echo "==========================================" >&2

# ── Parse exit code from Claude output ──────────────────────────────────────────
EXIT_CODE=0
if echo "$CLAUDE_OUTPUT" | grep -q '\[EXIT:1\]'; then
    EXIT_CODE=1
elif echo "$CLAUDE_OUTPUT" | grep -q '\[EXIT:2\]'; then
    EXIT_CODE=2
fi

exit "$EXIT_CODE"
