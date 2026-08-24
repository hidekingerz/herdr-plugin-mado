# herdr-plugin-mado

[herdr](https://herdr.dev) plugins that put [mado](https://github.com/hidekingerz/mado),
a TUI markdown viewer, in front of you while you work with agents.

An agent writing a plan, a report or a running log leaves you reading
markdown in a pager, or scrolling back through the pane it was printed
in. These plugins open that markdown in mado instead — in its own pane,
beside the agent that is writing it.

## Plugins

| Plugin | Install | What it does |
| ------ | ------- | ------------ |
| [`docs-peek`](docs-peek) | `herdr plugin install hidekingerz/herdr-plugin-mado/docs-peek` | Opens the focused pane's `docs/` in mado, in a split to the right. |
| [`agent-report-viewer`](agent-report-viewer) | `herdr plugin install hidekingerz/herdr-plugin-mado/agent-report-viewer` | Opens the markdown an agent run produced, in mado, when the run is done. |
| [`loop-dash`](loop-dash) | `herdr plugin install hidekingerz/herdr-plugin-mado/loop-dash` | Keeps a `loop/` agent loop's `MEMORY.md` / `VISION.md` on screen in a mado pane that follows the files. |

## docs-peek

Press the key you bind to it and mado opens beside the agent, rooted at
the directory that agent is working in.

The directory is taken from the focused pane's cwd — the agent you were
just looking at — falling back to the workspace cwd when herdr cannot
resolve one. If that directory has a `docs/`, mado is rooted there;
otherwise it opens the whole tree and the sidebar does the work. When
the installed mado supports `--watch`, the pane reloads by itself as the
agent rewrites the files.

### Install

```sh
herdr plugin install hidekingerz/herdr-plugin-mado/docs-peek
herdr plugin action list --plugin mado.docs-peek
```

Then bind a key in your herdr config:

```toml
[[keys.command]]
key = "prefix+d"
type = "plugin_action"
command = "mado.docs-peek.peek"
description = "peek at docs with mado"
```

It also runs without a keybinding:

```sh
herdr plugin action invoke mado.docs-peek.peek
```

### Requirements

- herdr 0.8.0 or newer
- [mado](https://github.com/hidekingerz/mado) on your `PATH` —
  `go install github.com/hidekingerz/mado@latest`, or a binary from the
  [releases page](https://github.com/hidekingerz/mado/releases)
- Linux or macOS. The entrypoints are POSIX shell scripts, so Windows is
  not supported yet even though mado itself runs there.
- `jq` is used when present and not needed otherwise; the plugin reads
  the one field it wants out of the invocation context either way.

### Developing

```sh
git clone https://github.com/hidekingerz/herdr-plugin-mado
herdr plugin link herdr-plugin-mado/docs-peek
herdr plugin action invoke mado.docs-peek.peek
herdr plugin log list --plugin mado.docs-peek
```

`herdr plugin unlink mado.docs-peek` when you are done.

## agent-report-viewer

When an agent run finishes, this plugin looks at the uncommitted `*.md`
files in that agent pane's git work tree and opens them in mado — newest
first, up to four files. Each workspace gets one mado pane; a later run
adds tabs to that same pane instead of opening a new one, so the reports
from a working session collect in one place beside the agent.

### Install

```sh
herdr plugin install hidekingerz/herdr-plugin-mado/agent-report-viewer
```

It subscribes to the `pane.agent_status_changed` event rather than a
keybinding, so there is nothing further to set up — it runs on its own
whenever an agent run in a git repository finishes.

### Requirements

- herdr 0.8.0 or newer
- [mado](https://github.com/hidekingerz/mado) v1.2.0 or newer on your
  `PATH` — this plugin needs `-remote open` and `-watch`, which older
  mado builds don't have
- A git repository. Runs outside one are skipped.
- Linux or macOS. The entrypoints are POSIX shell scripts, so Windows is
  not supported yet even though mado itself runs there.

### Developing

```sh
git clone https://github.com/hidekingerz/herdr-plugin-mado
herdr plugin link herdr-plugin-mado/agent-report-viewer
herdr plugin log list --plugin mado.agent-report-viewer
```

`herdr plugin unlink mado.agent-report-viewer` when you are done.

## loop-dash

A single-agent loop keeps its state under `loop/` — `MEMORY.md`, the
memory it rewrites every iteration, and `VISION.md`, the goal and
definition of done it works toward. Press the key you bind to this
plugin and those files open in a mado pane that follows them as the loop
rewrites them.

The plugin looks in the focused pane's cwd for the known names
`loop/MEMORY.md` and `loop/VISION.md`, and opens every one it finds as a
tab, watching for changes. Each workspace gets one dashboard pane:
invoking the action again refreshes the same pane instead of opening
another. When none of the known files exist, nothing happens.

### Install

```sh
herdr plugin install hidekingerz/herdr-plugin-mado/loop-dash
herdr plugin action list --plugin mado.loop-dash
```

Then bind a key in your herdr config:

```toml
[[keys.command]]
key = "prefix+t"
type = "plugin_action"
command = "mado.loop-dash.show"
description = "show loop state in mado"
```

It also runs without a keybinding:

```sh
herdr plugin action invoke mado.loop-dash.show
```

### Requirements

- herdr 0.8.0 or newer
- [mado](https://github.com/hidekingerz/mado) v1.2.0 or newer on your
  `PATH` — this plugin needs `-remote open` and `-watch`, which older
  mado builds don't have
- Linux or macOS. The entrypoints are POSIX shell scripts, so Windows is
  not supported yet even though mado itself runs there.
- `jq` is used when present and not needed otherwise.

### Developing

```sh
git clone https://github.com/hidekingerz/herdr-plugin-mado
herdr plugin link herdr-plugin-mado/loop-dash
herdr plugin action invoke mado.loop-dash.show
herdr plugin log list --plugin mado.loop-dash
```

`herdr plugin unlink mado.loop-dash` when you are done.

## Planned

Tracked in [hidekingerz/mado#13](https://github.com/hidekingerz/mado/issues/13):

- **markdown link handler** — Control+click a `.md` path in any pane and
  send it to mado. Wants mado's `--remote open` so it lands as a tab in
  the pane you already have open.

## License

[Apache-2.0](LICENSE)
