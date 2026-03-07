# Claude-forge
Tools for claude

---

## jira-automation.sh

Automates the full workflow from a Jira ticket to a reviewed Azure DevOps PR.

### What it does

1. Reads the Jira ticket (title, description, all comments) via MCP
2. Creates a `fix/<TICKET>-<slug>` branch from `main` and pushes it
3. Opens a Pull Request in Azure DevOps targeting `main`
4. Analyses the codebase to locate the reported issue
5. **If the problem is unclear or not fixable** — posts a PR comment explaining why and what is missing
6. **If fixable** — implements the fix, runs tests and build until they pass, then posts a PR comment summarising the changes

### Usage

```bash
./jira-automation.sh <JIRA-TICKET-ID>
```

```bash
# Example
./jira-automation.sh PROJ-123
```

Run from inside the target git repository.

### Requirements

- [`claude` CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- Jira and Azure DevOps MCP servers configured in user settings (`~/.claude.json`)
  ```bash
  claude mcp add   # to register a new MCP server
  ```
