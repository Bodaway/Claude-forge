# Claude-forge
Tools for claude

---

## jira-automation.sh

Automates the full workflow from a Jira ticket to a reviewed Azure DevOps PR.

### What it does

1. Reads the Jira ticket (title, description, all comments) via MCP
2. Creates a `fix/<TICKET>-<slug>` branch from the default branch and pushes it
3. Updates Jira status to **EN COURS**
4. Opens a Pull Request in Azure DevOps
5. Analyses the codebase to locate the reported issue
6. **If the problem is unclear or not fixable** — posts a PR comment explaining why and what is missing
7. **If fixable** — implements the fix, runs tests and build until they pass, then posts a PR comment summarising the changes

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

## git-jira-analysis.sh

Audits consistency between Jira ticket statuses and Azure DevOps Pull Requests. Detects tickets whose Jira status does not match the expected PR state (open, merged, or absent).

### Consistency rules

| Jira status | Expected PR state |
|---|---|
| 0 – 3 (pre-dev) | No PR — warn if one exists |
| 4 EN COURS, 5 A TESTER EN INTERNE | PR must be **open** |
| 6 A DÉPLOYER EN RECETTE | Transitional — warn if no PR at all |
| 7 A RECETTER, 8 A RECETTER (S), 10.x PRODUCTION | PR must be **merged** |
| 9 A CORRIGER | Previous PR **merged** + new correction PR **open** |
| 12.x BLOQUÉ / EN PAUSE | Informational flag |
| 13 ABANDONNÉ, 14 CLOS | No PR should remain open |

### Usage

```bash
./git-jira-analysis.sh <PROJECT-KEY> [options]
```

| Option | Description |
|---|---|
| `--sprint <name>` | Filter by sprint name |
| `--tickets ID1,ID2,...` | Analyse specific tickets only |
| `--output <file>` | Save report to file |
| `--json` | Output structured JSON (for CI pipelines) |
| `--verbose` | Show progress during analysis |

```bash
# All active tickets in the project
./git-jira-analysis.sh PROJ

# Only a specific sprint
./git-jira-analysis.sh PROJ --sprint "Sprint 42"

# Specific tickets, save report
./git-jira-analysis.sh PROJ --tickets PROJ-101,PROJ-102 --output report.md

# JSON output for CI
./git-jira-analysis.sh PROJ --json
```

### Exit codes

| Code | Meaning |
|---|---|
| 0 | No issues found |
| 1 | Violations found (blocking inconsistencies) |
| 2 | Warnings only (non-blocking) |

Run from inside the target git repository.

### Requirements

- [`claude` CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- Jira and Azure DevOps MCP servers configured in user settings (`~/.claude.json`)
