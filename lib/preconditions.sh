#!/bin/bash
# lib/preconditions.sh
# Shared precondition checks for Claude-forge scripts.
# Source this file from any script: source "$(dirname "$0")/lib/preconditions.sh"

# Resolve the script's own directory (handles symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

# ── Git repository check ────────────────────────────────────────────────────────
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Must be run from within a git repository."
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)

# ── Detect default branch ───────────────────────────────────────────────────────
# Tries origin/HEAD first, then falls back to main or master.
detect_default_branch() {
    local ref
    ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    if [ -n "$ref" ]; then
        echo "$ref"
        return
    fi
    # Fallback: check which branch exists on the remote
    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        echo "main"
    elif git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        echo "master"
    else
        echo "main"  # last resort default
    fi
}

DEFAULT_BRANCH=$(detect_default_branch)

# ── MCP config check ────────────────────────────────────────────────────────────
GLOBAL_MCP_CONFIG="${HOME}/.claude.json"
if [ ! -f "$GLOBAL_MCP_CONFIG" ]; then
    echo "Error: User Claude config not found at $GLOBAL_MCP_CONFIG"
    echo "Please configure Jira and Azure DevOps MCP servers via: claude mcp add"
    exit 1
fi

# ── Claude CLI check ────────────────────────────────────────────────────────────
if ! command -v claude &> /dev/null; then
    echo "Error: 'claude' CLI not found. Please install Claude Code."
    echo "See: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi
