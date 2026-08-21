#!/bin/sh
# Action entrypoint: work out which directory the focused pane is in and
# open mado on it in a split to the right.
set -eu

context=${HERDR_PLUGIN_CONTEXT_JSON:-}

# Read one string field out of the invocation context. jq when it is
# installed; a narrow sed fallback when it is not, so that the plugin
# stays a two-file install with no dependencies of its own. herdr emits
# compact JSON, so the fallback pattern is enough for ordinary paths.
context_field() {
	if [ -z "$context" ]; then
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$context" | jq -r --arg key "$1" '.[$key] // empty'
	else
		printf '%s' "$context" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p'
	fi
}

# The focused pane is the agent you were looking at. Fall back to the
# workspace when herdr could not resolve a pane cwd (a pane running a
# process whose cwd is not readable, for instance).
base=$(context_field focused_pane_cwd)
if [ -z "$base" ]; then
	base=$(context_field workspace_cwd)
fi
if [ -z "$base" ]; then
	base=$PWD
fi

# docs/ is the interesting directory when there is one; otherwise show
# the whole tree and let the sidebar do the work.
target=$base
if [ -d "$base/docs" ]; then
	target=$base/docs
fi

herdr=${HERDR_BIN_PATH:-herdr}
exec "$herdr" plugin pane open \
	--plugin mado.docs-peek \
	--entrypoint docs \
	--placement split \
	--direction right \
	--cwd "$target" \
	--env "MADO_DOCS_PEEK_DIR=$target" \
	--focus
