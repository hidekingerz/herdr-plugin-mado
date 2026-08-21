#!/bin/sh
# Pane entrypoint: run mado on the directory the action picked.
set -eu

dir=${MADO_DOCS_PEEK_DIR:-.}

if ! command -v mado >/dev/null 2>&1; then
	printf 'mado is not on PATH.\n\n' >&2
	printf 'Install it with:  go install github.com/hidekingerz/mado@latest\n' >&2
	printf 'or from https://github.com/hidekingerz/mado/releases\n\n' >&2
	printf 'Press Enter to close this pane.' >&2
	read -r _ || true
	exit 127
fi

# --watch keeps the pane in step with whatever the agent writes. Older
# mado builds do not have it, so fall back rather than fail to start.
if mado -h 2>&1 | grep -q -- '-watch'; then
	exec mado --watch "$dir"
fi
exec mado "$dir"
