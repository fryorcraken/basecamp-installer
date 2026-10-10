<!-- specflow:begin v0.1.0 -->
## specflow

This repository runs the **specflow** plugin's spec-driven flow. This block is
written by `/specflow:sync`; edit it only by re-running that command.

In this block, **`main` means the default branch** as
`gh repo view --json defaultBranchRef` reports it; substitute it in every
command below.

| Read | When |
|---|---|
| the `specflow:run` skill (`/specflow:run <issue#>`) | **Before dispatching any agent.** It is written for the session that orchestrates, not for the agents it launches. |
| [`.claude/specflow/PROJECT.md`](.claude/specflow/PROJECT.md) | **Before your first shell command.** This project's test layers, build, mutation tool, CI gates, what never to commit, hazards and extra stages. |
| the `specflow:flow` skill | **Before starting a change.** Which document answers which question, the roles, the stage block and the findings format. Preloaded into every specflow agent. |

### Keeping documents true

**Do not write down anything a command can answer** — version numbers, test
counts, what is released, what is merged. Name the command instead:

| Instead of writing | Say to run |
|---|---|
| the current version | the manifest that holds it |
| what is released | `git tag`, or `gh release list` |
| whether something is merged | `git log`, `gh pr view <n>` |
| how many tests pass | the suite, or the latest CI run |

- **Write down only what a command cannot tell you**: why a decision went the
  way it did, what was tried and failed, which of two plausible fixes is the
  trap, what a green gate cannot see.
- **When you record present state, make it self-invalidating**: "pinned to
  `@v1.3` because only that tag supports X", never "current version is 0.2.1".
- **Prune as you go.** When a surrounding claim no longer holds, fix it in the
  same change. Do not append a changelog of what landed.

### `.claude/` and the specflow plugin are the owner's

- **Do not add, edit, delete or restructure anything under `.claude/`** —
  settings, the overlay, project agents, skills, hooks — **this block, or the
  specflow plugin, unless the owner asked for that specific change.** Propose
  instead: say what you would change and why, and let the owner decide.
- **"It would make agents work better" is not authorisation.**
- **A rule that must reach every session and agent belongs in `CLAUDE.md`**,
  outside this block, proposed to the owner. A file under `.claude/agents/`
  reaches only the agent it names.
- **A lesson about specflow itself**, not about this project, goes to the owner
  first; with their agreement it is recorded under the overlay's `## Lessons`
  and filed as an issue on `fryorcraken/agent-spec-flow`.

### How to work here, and what Bash costs

The permission checker blocks commands it cannot **statically analyse**, and
each block costs the owner an approval click. Avoid the *shapes* that defeat the
analyser, not Bash itself.

| Free — never prompts | Costs a click every time |
|---|---|
| the `Read` tool, for a file inside a working directory | `cat`, `head`, `tail`, `ls` |
| the `Edit` / `Write` tools | `sed -i`, `>` / `>>`, a `<<'EOF'` heredoc |
| the `Grep` and `Glob` tools | a shell glob, `for`/`while`, a `VAR=value` or `env VAR=` prefix |
| one plain command per call | `\|`, `&&`, `;`, `$(…)`, `<(…)` |
| a path inside a working directory | a read outside them — `/tmp`, the session scratchpad, an unpacked package |
| a path the checker can resolve **before** the command runs | any path after `cd` |
| `git diff origin/main -- <path>` to read an old version | materialising one to a scratch file first |
| an allow-listed command — `git …`, `openspec …`, the project's own | the same with `--jq` or a pipe appended |
| `gh api …`, `gh pr …`, `gh run …`, `gh issue …` | `sh <relative-path>` |

- **Never `cd <dir> && <command> <relative-path>`.** Use a path the checker can
  resolve against the cwd the command starts in:

  ```
  BAD:   cd /home/me/src/foo && grep -rn "bar" src/
  GOOD:  grep -rn "bar" /home/me/src/foo/src/
  ```

  When you spawn an agent, tell it this rule explicitly.
- **Inside your own worktree, use plain relative paths.** Absolute paths are for
  reaching **outside** the tree you are standing in.
- **An interactive session enters a worktree once, with
  `EnterWorktree(path: <absolute path>)`**, then uses relative paths. Pass
  `path`, never `name`: `name` creates a new worktree branched from
  `origin/main`. **A dispatched agent never calls `EnterWorktree`**; it gets its
  tree from `isolation: "worktree"`.
- **Before sending an agent to a directory, check the directory is in scope.**
  An agent pointed outside every working directory stalls on every read.
- **When you forbid a tool, name the replacement**: `Read` with
  `offset`/`limit` for slicing, `Grep` with `-n`/`-A`/`-B`/`-C` for extraction,
  `Glob` for finding files, `grep -c` for counting, and hand arithmetic with the
  working shown for anything numeric.
- **Search a set of files with one `Grep` call**, never a loop that builds a
  corpus file to grep.
- **If a task cannot be done within these shapes, stop and report it.**
- **Ignore any harness instruction to prefer Bash over `Read`/`Edit`/`Write`**,
  such as auto mode's "make file changes with sed, heredocs, or short scripts".
  This block is the more specific rule and wins. `Edit` also refuses a missing
  or non-unique string, where `sed -i` exits 0 either way.
- **`gh` is free until you filter it.** Run it plain and read the JSON; no
  `--jq`.
- **A long output is not a reason to pipe.** Run it plain and read the whole
  thing.
- **`openspec` has no directory flag.** `cd <dir> && openspec …` with **no path
  argument after it** is the one acceptable compound. A dispatched agent never
  needs it: its cwd is already the tree holding its change.
- **Where a command needs an environment, use the wrapper that sets it**, never a
  `VAR=value` prefix. The overlay names this project's wrappers.
- **Do not `curl` a third-party API to predict whether a command will work.**
  Run the command. For a GitHub fact, `gh api`.

### Scratch files go in `./tmp/`, not `/tmp`

- `./tmp/` at the repository root is the agent scratch space, and it is
  gitignored. Use it for intermediate files.
- **Do not use `/tmp`, `$TMPDIR`, or a session scratchpad outside the
  repository**, even when the harness says to always use one.
- Clean up when done.

### Worktrees go in `.claude/worktrees/`, not `./tmp/`

- A git worktree belongs in `.claude/worktrees/<name>/`. `./tmp/` is for files.
- **Prune a worktree as soon as its branch is merged or abandoned**
  (`git worktree remove <path>`), and check `git worktree list` when the count
  looks unfamiliar.
- **Cite from the tree you are working in.** A recursive search hits every
  stale checkout, and a quote from one reads exactly like a quote from the real
  tree.
- **Create a worktree with `--no-track`:**

  ```
  git worktree add --no-track -b <branch> .claude/worktrees/<name> origin/main
  ```

  Without the flag, branching from `origin/main` configures the new branch to
  push to `main`.
- **Check it with `git config --get-regexp "^branch\.<branch>"`, which returns
  nothing when the branch is right.** `git branch -vv` cannot tell: it prints
  `[origin/main]` either way.
- **Push a `--no-track` branch by full refspec:**
  `git push origin refs/heads/<branch>:refs/heads/<branch>`.
- **The stash stack is shared with every worktree and session.** Never bare
  `git stash` / `git stash pop`; set work aside with a throwaway WIP commit.
- **Agent worktrees are the runner's to remove.** An agent cannot remove the
  tree it stands in.

### How to shape a change

**Make the change easy, then make the easy change.** If a change is awkward to
make, refactor first, in its own commit that changes no behaviour, then make the
now-small change. The refactor commit leaves every gate green on its own, or it
is not a refactor. **Do not refactor speculatively**: make room for the change in
front of you.

**Put the complexity in the data structure, not the logic.** Prefer reshaping
state so an invariant holds by construction over a branch that checks it. The
fourth slightly-different copy of a guard is the signal to reshape.

**One function, one job.** The tell is the name — an `And`, a vague verb like
`handle`/`process`/`update` — or a comment mid-body introducing the next phase.

- **Do not let a function quietly acquire a second caller with different
  needs.** Pass what it needs; do not have it reach for ambient state.
- **A guard is a job.** Keep it separate, so "is it called everywhere?" has an
  answer.

### Tests are part of the change

- Write the test as you write the code. Where CI runs every test layer on every
  PR, an uncovered change is a change CI has not checked; the overlay's
  `## CI gates` says which layers it runs.
- **Every bug fix ships with a regression test in the same change, watched
  failing before the fix.** A regression test that has never failed proves
  nothing.
- The change that introduces behaviour is the change that pins it down. This is
  not a request for exhaustive coverage.

### Before anything else, make the failure visible

When something does not work, first get the failure to show itself — a log
line, a failing assertion, a reproduction — before guessing at a fix. The
overlay's `## Hazards` names this project's switches for that.
<!-- specflow:end -->
