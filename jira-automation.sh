#!/bin/bash
# jira-automation.sh
# Automates: Jira ticket read → Azure DevOps branch + PR → code analysis → fix or explain → PR comment
#
# Usage: ./jira-automation.sh <JIRA-TICKET-ID>
# Example: ./jira-automation.sh PROJ-123
#
# Requirements:
#   - claude CLI installed (Claude Code)
#   - .mcp.json in the repo root with Jira and Azure DevOps MCP servers configured
#   - Must be run from within the target git repository

set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────────────────
JIRA_TICKET="${1:-}"

if [ -z "$JIRA_TICKET" ]; then
    echo "Usage: $0 <JIRA-TICKET-ID>"
    echo "Example: $0 PROJ-123"
    exit 1
fi

# ── Precondition checks ─────────────────────────────────────────────────────────
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Must be run from within a git repository."
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
MCP_CONFIG="$REPO_ROOT/.mcp.json"

if [ ! -f "$MCP_CONFIG" ]; then
    echo "Error: .mcp.json not found at $MCP_CONFIG"
    echo "Please add an .mcp.json file with your Jira and Azure DevOps MCP server configurations."
    exit 1
fi

if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' CLI not found. Please install Claude Code."
    echo "See: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

# ── Info banner ─────────────────────────────────────────────────────────────────
echo "=========================================="
echo " Jira Automation Script"
echo "=========================================="
echo " Ticket  : $JIRA_TICKET"
echo " Repo    : $REPO_ROOT"
echo " MCP cfg : $MCP_CONFIG"
echo "=========================================="
echo ""

# ── Build Claude prompt ─────────────────────────────────────────────────────────
PROMPT=$(cat <<CLAUDE_PROMPT
You are an automated code assistant. Your task is to resolve Jira ticket **${JIRA_TICKET}** by following the steps below precisely and in order.

---

## Step 1 — Fetch Jira Ticket

Use the Jira MCP tools to read ticket **${JIRA_TICKET}**. Collect:
- Title / Summary
- Full description
- All comments (read every comment)
- Priority and current status

---

## Step 2 — Create a Local Branch

Based on the ticket title, derive a short kebab-case slug (max 5 words, lowercase, no special characters).

Then run:
\`\`\`
git -C "$REPO_ROOT" checkout main
git -C "$REPO_ROOT" pull origin main
git -C "$REPO_ROOT" checkout -b fix/${JIRA_TICKET}-<short-slug>
\`\`\`

---

## Step 3 — Push Branch and Create PR

Push the new branch to the remote:
\`\`\`
git -C "$REPO_ROOT" push -u origin fix/${JIRA_TICKET}-<short-slug>
\`\`\`

Then use the Azure DevOps MCP to create a Pull Request:
- **Source branch:** fix/${JIRA_TICKET}-<short-slug>
- **Target branch:** main
- **Title:** [${JIRA_TICKET}] <Jira ticket title>
- **Description:** Auto-generated from Jira ticket ${JIRA_TICKET}. Analysis and implementation in progress.

Record the PR ID / URL for later use.

---

## Step 4 — Analyze the Codebase

Thoroughly read the repository at $REPO_ROOT to understand:
- Project structure and technology stack
- The specific problem described in ${JIRA_TICKET}
- The exact location(s) in the code where the issue originates
- The scope and risk of the necessary change

---

## Step 5 — Decision: Implement or Explain

### Case A — Problem is UNCLEAR or RESOLUTION IS NOT POSSIBLE

If any of these apply:
- Requirements are ambiguous or contradictory
- The root cause cannot be identified in the current codebase
- The change would be too risky or outside this repository's scope
- Required context (credentials, external services, schemas) is missing

→ **Do NOT make any code changes.**
→ Post a PR comment that explains:
  - Which parts of the ticket are unclear or missing
  - Why a resolution cannot be implemented
  - What additional information or actions are needed

### Case B — Resolution IS POSSIBLE

Implement the minimal, focused fix:
- Change only what is necessary to resolve the issue
- Follow the existing coding style and conventions of the project
- Commit the changes:
  \`\`\`
  git -C "$REPO_ROOT" add -p   # stage only relevant changes
  git -C "$REPO_ROOT" commit -m "fix(${JIRA_TICKET}): <concise description of the fix>"
  \`\`\`

---

## Step 6 — (Case B only) Run Tests and Build

Auto-detect the test and build commands from the project (check package.json scripts, Makefile, pom.xml, pyproject.toml, etc.).

1. **Run tests** — if tests fail, diagnose and fix the failures, then re-run until all pass.
2. **Run build** — if the build fails, diagnose and fix the issues, then re-run until it succeeds.
3. Commit any additional fixes with message: \`fix(${JIRA_TICKET}): fix tests/build after main fix\`
4. Push all commits: \`git -C "$REPO_ROOT" push\`

---

## Step 7 — Post PR Comment

Add a detailed, professional comment to the Azure DevOps PR (use the PR ID recorded in Step 3) containing:

**If Case A (not resolved):**
- Summary of the analysis performed
- Specific reasons why the issue could not be resolved
- Recommendations for next steps

**If Case B (resolved):**
- Description of the root cause found
- Summary of changes made, with file names and a brief rationale for each
- Test results (passed/failed counts, build status)
- Any known limitations or follow-up work suggested

---

Work carefully and methodically. Do not skip any step.
CLAUDE_PROMPT
)

# ── Invoke Claude ────────────────────────────────────────────────────────────────
echo "Starting Claude automation workflow..."
echo ""

claude \
    --dangerouslySkipPermissions \
    --mcp-config "$MCP_CONFIG" \
    -p "$PROMPT"

echo ""
echo "=========================================="
echo " Automation complete for: $JIRA_TICKET"
echo "=========================================="
