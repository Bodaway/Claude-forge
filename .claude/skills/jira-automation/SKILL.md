---
name: jira-automation
description: Automates Jira ticket resolution — branch creation, code analysis, fix implementation, Azure DevOps PR creation, and PR commenting. Invoke with a Jira ticket ID, e.g., /jira-automation PROJ-123. TRIGGER when the user wants to resolve, fix, or work on a Jira ticket end-to-end.
---

# Jira Ticket Automation

Automate the full lifecycle of resolving a Jira ticket: fetch details, create a branch, analyze the code, implement a fix (or explain why it cannot be fixed), create a PR, run tests, and post results.

Make a todo list for all the tasks in this workflow and work on them one after another.

---

## Step 0 — Parse Arguments and Validate Preconditions

1. **Extract the Jira ticket ID** from the skill argument (the text after `/jira-automation`). It must match the pattern `[A-Z]+-[0-9]+` (e.g., `PROJ-123`). If missing or malformed, stop and ask the user to provide a valid ticket ID.

2. **Confirm you are inside a git repository:**
   ```bash
   git rev-parse --git-dir
   ```
   If this fails, stop with an error: "This skill must be run from within a git repository."

3. **Detect the default branch** by running:
   ```bash
   git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'
   ```
   If that returns nothing, check if `refs/remotes/origin/main` exists, then `refs/remotes/origin/master`. Default to `main` as a last resort.

4. **Verify Jira MCP tools** are available by attempting a lightweight Jira MCP call. If the tools are not available, stop and instruct the user to configure the Jira MCP server via `claude mcp add`.

---

## Step 1 — Fetch Jira Ticket

Use the Jira MCP tools to read the ticket. Collect:
- Title / Summary
- Full description
- All comments (read every comment)
- Priority and current status

---

## Step 2 — Create a Local Branch

Based on the ticket title, derive a short kebab-case slug (max 5 words, lowercase, no special characters).

Then run:
```bash
git checkout <default-branch>
git pull origin <default-branch>
git checkout -b fix/<TICKET-ID>-<slug>
```

If a branch with that name already exists, append a numeric suffix (e.g., `-2`).

---

## Step 2.5 — Update Jira Status to EN COURS

Use the Jira MCP tools to transition the ticket to status **"4. EN COURS (W)"**.
If the transition fails (e.g., not a valid transition from the current status), log a warning but continue.

---

## Step 3 — Push Branch and Create PR

Push the new branch to the remote:
```bash
git push -u origin fix/<TICKET-ID>-<slug>
```

Then use the Azure DevOps MCP to create a Pull Request:
- **Source branch:** `fix/<TICKET-ID>-<slug>`
- **Target branch:** the default branch detected in Step 0
- **Title:** `[<TICKET-ID>] <Jira ticket title>`
- **Description:** Auto-generated from Jira ticket. Analysis and implementation in progress.

Record the PR ID / URL for later use.

---

## Step 4 — Analyze the Codebase

Thoroughly read the repository to understand:
- Project structure and technology stack
- The specific problem described in the Jira ticket
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

**Do NOT make any code changes.** Prepare a detailed explanation for the PR comment in Step 7.

### Case B — Resolution IS POSSIBLE

Implement the minimal, focused fix:
- Change only what is necessary to resolve the issue
- Follow the existing coding style and conventions of the project
- Commit the changes:
  ```bash
  git add <list of changed files>
  git commit -m "fix(<TICKET-ID>): <concise description of the fix>"
  ```
  **Important:** Do NOT use `git add -p` (interactive mode). Explicitly list the files you changed.

---

## Step 6 — Run Tests and Build (Case B only)

Auto-detect the test and build commands from the project (check `package.json` scripts, `Makefile`, `pom.xml`, `pyproject.toml`, etc.).

1. **Run tests** — if tests fail, diagnose and fix the failures, then re-run until all pass.
2. **Run build** — if the build fails, diagnose and fix the issues, then re-run until it succeeds.
3. Commit any additional fixes with message: `fix(<TICKET-ID>): fix tests/build after main fix`
4. Push all commits: `git push`

---

## Step 7 — Post PR Comment

Add a detailed, professional comment to the Azure DevOps PR (use the PR ID recorded in Step 3).

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

## Wrap Up

Work carefully and methodically. Do not skip any step. When finished, present a summary to the user:

* **Ticket:** the Jira ticket ID
* **Branch:** the branch name created
* **PR:** the PR URL
* **Outcome:** Case A (explained) or Case B (fixed)
* **Test/Build results** (if Case B): pass/fail counts and build status
