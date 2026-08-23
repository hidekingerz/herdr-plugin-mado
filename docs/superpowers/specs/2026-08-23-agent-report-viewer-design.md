# agent-report-viewer — design

2026-08-23. Approved in conversation before writing this spec.

## Purpose

When an agent run finishes, show the markdown that run produced —
without the user having to notice the run finished, find the files, and
open them. The plugin subscribes to herdr's agent status events and
opens the produced markdown in [mado](https://github.com/hidekingerz/mado),
reusing one mado pane per workspace.

First of the three planned plugins in this repository; the other two
(markdown link handler, loop-state dashboard) are out of scope here.

## Constraints

- herdr 0.8.0+, mado v1.2.0+ (`-remote`, `-watch`) on `PATH`.
- Same shape as docs-peek: a plugin directory of POSIX shell scripts and
  a `herdr-plugin.toml`; no build step, no daemon. Linux and macOS.
- The hook runs on every agent status change. It must never get in the
  user's way: every failure mode degrades to "do nothing", silently.

## Structure

New directory `agent-report-viewer/`, plugin id `mado.agent-report-viewer`:

| File | Role |
| ---- | ---- |
| `herdr-plugin.toml` | Manifest: event subscription + pane entrypoint |
| `on-agent-done.sh` | Event hook: detect produced markdown, route to a pane |
| `pane.sh` | Pane entrypoint: run mado on the detected files |

## Event subscription

```toml
[[events]]
on = "pane_agent_status_changed"
command = ["sh", "-c", "exec sh \"$HERDR_PLUGIN_ROOT/on-agent-done.sh\""]
```

- Event commands receive `HERDR_PLUGIN_EVENT` / `HERDR_PLUGIN_EVENT_JSON`.
  The payload carries `pane_id`, `workspace_id`, `agent_status`
  (`idle | working | blocked | done | unknown`).
- The hook exits immediately unless `agent_status` is `done`.
- All entrypoints are addressed through `$HERDR_PLUGIN_ROOT` because
  herdr runs plugin commands in the pane's (or event's) cwd, not the
  plugin root — the docs-peek 0.1.0 lesson.

## Detecting the produced markdown

Git-diff based, chosen over mtime tracking for simplicity and for
matching the intuition "the run's output is what is written but not
yet committed":

1. Resolve the agent pane's cwd via `herdr pane get <pane_id>`
   (`HERDR_BIN_PATH`).
2. If the cwd is not inside a git work tree: exit silently.
3. `git -C <cwd> status --porcelain` → keep modified and untracked
   paths ending in `.md`.
4. Sort by mtime, newest first; cap at 4 files.
5. Zero candidates: exit silently.

The cap guards against runs that touch many markdown files; the newest
files are the most likely to be the report.

## Showing the report (one pane per workspace)

- The plugin keeps one mado pane per workspace. The pane id for each
  workspace is recorded in `HERDR_PLUGIN_STATE_DIR` when a pane is
  opened.
- If a recorded pane still exists (verify via `herdr pane get`; stale
  records are dropped): hand the files to the running mado with
  `mado -remote open <files…>`.
- Otherwise: `herdr plugin pane open --entrypoint report --placement
  split --direction right --cwd <cwd>` with the file list passed via
  `--env MADO_REPORT_FILES=<newline-separated paths>`; `pane.sh` runs
  `mado --watch <cwd> <files…>` (files open as tabs; `--watch` keeps
  them live while the user reads).

## Error handling

Every failure — no git, no mado, pane vanished, unparsable payload —
means "do nothing", exit 0, at most a line in the plugin log
(`herdr plugin log list`). The hook must never surface an error to the
user mid-session.

## Risks to verify first during implementation

1. **`mado -remote` addressing** — with several mado instances running
   (e.g. docs-peek's pane), confirm which instance receives `-remote
   open` and how to target the right one. If instances cannot be
   targeted, fall back to closing and reopening the plugin's own pane.
2. **`done` dedup** — confirm whether one run can emit
   `pane_agent_status_changed(done)` more than once; if so, dedupe via
   a per-pane marker in `HERDR_PLUGIN_STATE_DIR`.

## Testing

- Shell scripts are testable standalone: invoke `on-agent-done.sh` with
  a mocked `HERDR_PLUGIN_EVENT_JSON` and a scratch git repo; assert on
  the herdr/mado commands it would run (`HERDR_BIN_PATH` pointed at a
  stub).
- End-to-end manually in a live herdr session: run an agent that writes
  a markdown file → pane appears on done; run again → the same pane
  gains a tab instead of a second pane; run with no markdown changes →
  nothing happens.

## Out of scope

- Non-git directories (mtime fallback) — revisit if it hurts in practice.
- Cross-workspace aggregation, history of past reports, notifications.
- Windows.
