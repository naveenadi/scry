## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context layout. See `docs/agents/domain.md`.

## Worktree usage

Use Pi worktrees for isolated features, fixes, refactors, experiments, or parallel work. Skip them for read-only tasks or changes explicitly requested on the current branch.

- `/wt-create <branch>` – create and switch to a worktree
- `/wt-switch <branch>` – switch worktrees; use the default branch to return
- `/wt-merge [<branch>]` – merge and remove a completed worktree
- `/wt-cleanup [<branch>]` – remove an unused clean worktree

Before merging or deleting one, inspect its status and ensure no uncommitted work will be lost.
