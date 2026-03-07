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

---

## jira-review.sh

Automatically reviews all Jira tickets in "en test interne" status: finds the matching branch, performs a Claude-powered code review of the diff, and posts the result as a comment on the Azure DevOps PR.

### What it does

1. Queries Jira for tickets in "en test interne" status (or takes a single ticket via `--ticket`)
2. For each ticket, finds the branch matching the ticket key in the local repository
3. Computes the diff against the main branch
4. Uses Claude to perform a thorough code review (correctness, security, performance, maintainability, tests)
5. Posts the review as a structured comment on the corresponding Azure DevOps PR, labeled as **Claude Automated Code Review**

### Usage

```bash
./jira-review.sh <REPO_PATH> [--jira-project <KEY>] [--ticket <KEY>] [--main-branch <name>] [--dry-run]
```

```bash
# Review all "en test interne" tickets for project PROJ
./jira-review.sh ~/projects/my-app --jira-project PROJ

# Force review a single ticket (skips Jira status check)
./jira-review.sh ~/projects/my-app --ticket PROJ-123

# Dry run — see what would be reviewed without posting comments
./jira-review.sh ~/projects/my-app --jira-project PROJ --dry-run
```

### Requirements

- [`claude` CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- [`jq`](https://jqlang.github.io/jq/) installed
- Jira and Azure DevOps MCP servers configured in user settings (`~/.claude.json`)
  ```bash
  claude mcp add   # to register a new MCP server
  ```
