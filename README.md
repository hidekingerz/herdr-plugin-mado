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

## Planned

Tracked in [hidekingerz/mado#13](https://github.com/hidekingerz/mado/issues/13):

- **agent-report-viewer** — subscribe to agent `done` events and show the
  markdown that run produced.
- **markdown link handler** — Control+click a `.md` path in any pane and
  send it to mado. Wants mado's `--remote open` so it lands as a tab in
  the pane you already have open.
- **loop-state dashboard** — keep `TASKS.md` / `log.md` on screen in a
  pane that follows the file. Wants mado's `--watch`.

## License

[Apache-2.0](LICENSE)
