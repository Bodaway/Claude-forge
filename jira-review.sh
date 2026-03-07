#!/bin/bash
# jira-review.sh
# Reviews Jira tickets in "en test interne" status: finds local branches, reviews diffs via Claude, posts PR comments
#
# Usage: ./jira-review.sh <REPO_PATH> [--jira-project <KEY>] [--ticket <KEY>] [--main-branch <name>] [--dry-run]
# Example: ./jira-review.sh ~/projects/my-app --jira-project PROJ
# Example: ./jira-review.sh ~/projects/my-app --ticket PROJ-123
#
# Requirements:
#   - claude CLI installed (Claude Code)
#   - jq installed (JSON parsing)
#   - Jira and Azure DevOps MCP servers configured in user settings (~/.claude.json)

set -euo pipefail

# ── Argument parsing ────────────────────────────────────────────────────────────
REPO_PATH=""
JIRA_PROJECT=""
FORCE_TICKET=""
MAIN_BRANCH="main"
DRY_RUN=false

usage() {
    echo "Usage: $0 <REPO_PATH> [--jira-project <KEY>] [--ticket <KEY>] [--main-branch <name>] [--dry-run]"
    echo ""
    echo "Arguments:"
    echo "  <REPO_PATH>              Path to the git repository"
    echo ""
    echo "Options:"
    echo "  --jira-project <KEY>     Filter tickets by Jira project key"
    echo "  --ticket <TICKET-ID>     Force review of a single ticket (skips Jira status check)"
    echo "  --main-branch <name>     Base branch for diff (default: main)"
    echo "  --dry-run                List what would be reviewed without posting comments"
    echo ""
    echo "Examples:"
    echo "  $0 ~/projects/my-app --jira-project PROJ"
    echo "  $0 ~/projects/my-app --ticket PROJ-123"
    exit 1
}

# First positional argument is REPO_PATH
if [ $# -lt 1 ]; then
    usage
fi

REPO_PATH="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --jira-project)
            JIRA_PROJECT="${2:-}"
            [ -z "$JIRA_PROJECT" ] && { echo "Error: --jira-project requires a value"; exit 1; }
            shift 2
            ;;
        --ticket)
            FORCE_TICKET="${2:-}"
            [ -z "$FORCE_TICKET" ] && { echo "Error: --ticket requires a value"; exit 1; }
            shift 2
            ;;
        --main-branch)
            MAIN_BRANCH="${2:-}"
            [ -z "$MAIN_BRANCH" ] && { echo "Error: --main-branch requires a value"; exit 1; }
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'"
            usage
            ;;
    esac
done

# ── Precondition checks ─────────────────────────────────────────────────────────
if [ ! -d "$REPO_PATH" ]; then
    echo "Error: Repository path '$REPO_PATH' does not exist or is not a directory."
    exit 1
fi

if ! git -C "$REPO_PATH" rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: '$REPO_PATH' is not a git repository."
    exit 1
fi

REPO_PATH=$(cd "$REPO_PATH" && git rev-parse --show-toplevel)

GLOBAL_MCP_CONFIG="${HOME}/.claude.json"
if [ ! -f "$GLOBAL_MCP_CONFIG" ]; then
    echo "Error: User Claude config not found at $GLOBAL_MCP_CONFIG"
    echo "Please configure Jira and Azure DevOps MCP servers via: claude mcp add"
    exit 1
fi

if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' CLI not found. Please install Claude Code."
    echo "See: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' not found. Please install jq (JSON processor)."
    exit 1
fi

# ── Info banner ─────────────────────────────────────────────────────────────────
echo "=========================================="
echo " Jira Review Script"
echo "=========================================="
echo " Repo         : $REPO_PATH"
echo " Jira project : ${JIRA_PROJECT:-<all>}"
echo " Ticket       : ${FORCE_TICKET:-<auto-discover>}"
echo " Main branch  : $MAIN_BRANCH"
echo " Dry run      : $DRY_RUN"
echo " MCP cfg      : $GLOBAL_MCP_CONFIG (user settings)"
echo "=========================================="
echo ""

# ── Helper: find branch matching a ticket key ────────────────────────────────────
find_branch_for_ticket() {
    local ticket_key="$1"
    local repo="$2"

    # Search local branches first
    local matching
    matching=$(git -C "$repo" branch --list "*${ticket_key}*" --format='%(refname:short)' | head -1)
    if [ -n "$matching" ]; then
        echo "$matching"
        return 0
    fi

    # Fall back to remote-tracking branches
    matching=$(git -C "$repo" branch -r --list "*${ticket_key}*" --format='%(refname:short)' | head -1)
    if [ -n "$matching" ]; then
        # Strip remote prefix (e.g., origin/fix/PROJ-123-slug -> fix/PROJ-123-slug)
        local local_name="${matching#*/}"
        echo "$local_name"
        return 0
    fi

    return 1
}

# ── Step 1: Resolve ticket list ──────────────────────────────────────────────────
if [ -n "$FORCE_TICKET" ]; then
    echo "Mode: single ticket (forced, skipping Jira status check)"
    TICKETS_JSON="[{\"key\":\"${FORCE_TICKET}\",\"summary\":\"(forced review)\"}]"
else
    echo "Discovering tickets in 'en test interne' status..."

    PROJECT_FILTER=""
    if [ -n "$JIRA_PROJECT" ]; then
        PROJECT_FILTER=" in project ${JIRA_PROJECT}"
    fi

    DISCOVERY_PROMPT=$(cat <<PROMPT
You are an automated assistant. Use the Jira MCP tools to search for all tickets with status "en test interne"${PROJECT_FILTER}.

Output ONLY a JSON array, no markdown, no explanation, no code fences.
Each element must have exactly two fields: "key" and "summary".
Example format: [{"key": "PROJ-123", "summary": "Fix login bug"}]
If no tickets are found, output an empty array: []
PROMPT
)

    RAW_OUTPUT=$(claude --dangerouslySkipPermissions -p "$DISCOVERY_PROMPT" 2>/dev/null) || {
        echo "Error: Claude discovery call failed."
        exit 1
    }

    # Strip markdown fences if present
    TICKETS_JSON=$(echo "$RAW_OUTPUT" | sed '/^```/d' | sed '/^$/d' | tr -d '\r')

    # Try to extract JSON array from the output (Claude may add surrounding text)
    if ! echo "$TICKETS_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
        # Attempt to find a JSON array within the output
        TICKETS_JSON=$(echo "$RAW_OUTPUT" | grep -oP '\[.*\]' | head -1) || true
        if ! echo "$TICKETS_JSON" | jq -e 'type == "array"' > /dev/null 2>&1; then
            echo "Error: Failed to parse ticket list from Claude output."
            echo "Raw output:"
            echo "$RAW_OUTPUT"
            exit 1
        fi
    fi
fi

TICKET_COUNT=$(echo "$TICKETS_JSON" | jq 'length')
echo "Found $TICKET_COUNT ticket(s) to review."
echo ""

if [ "$TICKET_COUNT" -eq 0 ]; then
    echo "No tickets to review. Exiting."
    exit 0
fi

# ── Step 2: Review each ticket ───────────────────────────────────────────────────
REVIEWED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

# Save the current branch to restore later
ORIGINAL_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null) || ORIGINAL_BRANCH=""

# Process substitution to avoid subshell variable scoping issues
while IFS= read -r ticket; do
    TICKET_KEY=$(echo "$ticket" | jq -r '.key')
    TICKET_SUMMARY=$(echo "$ticket" | jq -r '.summary')

    echo "------------------------------------------"
    echo " Reviewing: $TICKET_KEY — $TICKET_SUMMARY"
    echo "------------------------------------------"

    # 2a. Find matching branch
    BRANCH_NAME=$(find_branch_for_ticket "$TICKET_KEY" "$REPO_PATH") || {
        echo "  SKIP: No branch found matching '$TICKET_KEY'"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo ""
        continue
    }
    echo "  Branch : $BRANCH_NAME"

    # 2b. Fetch and checkout
    git -C "$REPO_PATH" fetch origin 2>/dev/null || true

    # Check if branch exists locally, if not create from remote
    if ! git -C "$REPO_PATH" rev-parse --verify "$BRANCH_NAME" > /dev/null 2>&1; then
        git -C "$REPO_PATH" checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME" 2>/dev/null || {
            echo "  SKIP: Could not checkout branch '$BRANCH_NAME'"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            echo ""
            continue
        }
    else
        git -C "$REPO_PATH" checkout "$BRANCH_NAME" 2>/dev/null || {
            echo "  SKIP: Could not checkout branch '$BRANCH_NAME'"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            echo ""
            continue
        }
    fi

    # 2c. Compute diff
    DIFF_OUTPUT=$(git -C "$REPO_PATH" diff "${MAIN_BRANCH}...${BRANCH_NAME}" 2>/dev/null) || {
        echo "  SKIP: Could not compute diff against $MAIN_BRANCH"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo ""
        continue
    }

    if [ -z "$DIFF_OUTPUT" ]; then
        echo "  SKIP: No changes on branch $BRANCH_NAME vs $MAIN_BRANCH"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo ""
        continue
    fi

    DIFF_STATS=$(git -C "$REPO_PATH" diff --stat "${MAIN_BRANCH}...${BRANCH_NAME}" 2>/dev/null) || DIFF_STATS="(stats unavailable)"

    echo "  Diff stats:"
    echo "$DIFF_STATS" | sed 's/^/    /'

    # 2d. Dry-run gate
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY-RUN: Would review this diff and post comment to PR"
        REVIEWED_COUNT=$((REVIEWED_COUNT + 1))
        echo ""
        continue
    fi

    # 2e. Cap diff size
    MAX_DIFF_CHARS=100000
    if [ ${#DIFF_OUTPUT} -gt $MAX_DIFF_CHARS ]; then
        DIFF_OUTPUT="${DIFF_OUTPUT:0:$MAX_DIFF_CHARS}

... [TRUNCATED — diff too large, showing first ${MAX_DIFF_CHARS} characters] ..."
    fi

    # 2f. Claude Call 2: Code Review + PR Comment
    REVIEW_PROMPT=$(cat <<REVIEW_PROMPT_END
You are an automated code reviewer. Perform a thorough code review of the changes below, then post your review as a comment on the corresponding Azure DevOps Pull Request.

## Context
- Jira ticket: ${TICKET_KEY} — ${TICKET_SUMMARY}
- Repository: ${REPO_PATH}
- Branch: ${BRANCH_NAME} (compared against ${MAIN_BRANCH})

## Diff statistics
${DIFF_STATS}

## Full diff
\`\`\`diff
${DIFF_OUTPUT}
\`\`\`

## Instructions

### 1. Review the code changes
Evaluate the following aspects:
- **Correctness**: Does the code do what the ticket requires? Are there logic errors or bugs?
- **Security**: Any security concerns (injection, authentication, data exposure)?
- **Performance**: Any obvious performance issues?
- **Maintainability**: Code clarity, naming, structure, duplication
- **Error handling**: Are error cases properly handled?
- **Tests**: Are changes covered by tests? Are new tests needed?

### 2. Post the review to Azure DevOps
Use the Azure DevOps MCP tools to:
1. Find the Pull Request associated with branch "${BRANCH_NAME}" in this repository
2. Add a comment to that PR with your review formatted as follows:

---
## 🤖 Claude Automated Code Review — ${TICKET_KEY}

> This review was generated automatically by Claude AI.

### Summary
<One paragraph overall assessment: is this ready to merge, needs changes, or has blockers?>

### Findings

#### 🔴 Critical Issues
<List any bugs, security issues, or broken functionality. If none, write "None found.">

#### 🟡 Suggestions
<List improvement suggestions for code quality, performance, maintainability. If none, write "None.">

#### 🟢 Positive Notes
<List things done well.>

### Verdict
<One of: ✅ APPROVED / ⚠️ NEEDS CHANGES / 🚫 BLOCKED — with brief justification>
---

If you cannot find a PR for this branch, output the review to stdout instead and note that no PR was found.
REVIEW_PROMPT_END
)

    echo "  Running Claude code review..."
    if claude --dangerouslySkipPermissions -p "$REVIEW_PROMPT" 2>/dev/null; then
        echo "  Review posted for $TICKET_KEY"
        REVIEWED_COUNT=$((REVIEWED_COUNT + 1))
    else
        echo "  WARNING: Claude review failed for $TICKET_KEY"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi

    echo ""
done < <(echo "$TICKETS_JSON" | jq -c '.[]')

# ── Restore original branch ─────────────────────────────────────────────────────
if [ -n "$ORIGINAL_BRANCH" ]; then
    git -C "$REPO_PATH" checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
fi

# ── Summary ──────────────────────────────────────────────────────────────────────
echo "=========================================="
echo " Review complete"
echo "=========================================="
echo " Total tickets : $TICKET_COUNT"
echo " Reviewed      : $REVIEWED_COUNT"
echo " Skipped       : $SKIPPED_COUNT"
echo " Errors        : $ERROR_COUNT"
echo "=========================================="
