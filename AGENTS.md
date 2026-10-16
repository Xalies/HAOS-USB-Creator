## Synchronise repositories before starting work

For every project, before investigating or editing repository code, check the current branch, upstream, working tree and any unfinished merge or rebase. Fetch the latest changes from the relevant remote before starting work, including each additional repository the task requires.

If the checkout is clean, on a branch with an upstream, and no Git operation is in progress, run `git pull --ff-only` before working. If local and remote commits have diverged, integrate the upstream changes deliberately and resolve conflicts before making task changes, preserving local work.

Never discard edits, reset commits, force a checkout, automatically stash changes, or abort an existing Git operation just to pull. For a dirty checkout or an unfinished operation, inspect and preserve the existing work before integrating remote changes. For a detached worktree, fetch and compare against the intended base branch without switching branches or blindly pulling. Do not merge other worktrees unless requested.

If fetching fails or safe synchronisation needs a user decision, state the specific issue before making edits that depend on the missing changes. Do not claim the repository is current when the remote could not be checked. Recheck remote changes before a requested final merge or push. Do not push unless requested.

For projects without Git or a configured remote, skip pulling and mention that limitation when relevant.

