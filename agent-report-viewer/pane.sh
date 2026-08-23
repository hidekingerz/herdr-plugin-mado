#!/bin/sh
# Pane entrypoint: ランが生成した markdown を mado で開く。
# MADO_REPORT_FILES: 改行区切りの絶対パス。MADO_SOCKET: remote 用ソケット
# （herdr が --env で渡し、この mado が listen し、以後のフックが送り先にする）。
set -eu

if ! command -v mado >/dev/null 2>&1; then
	printf 'mado is not on PATH.\n\n' >&2
	printf 'Install it with:  go install github.com/hidekingerz/mado@latest\n' >&2
	printf 'or from https://github.com/hidekingerz/mado/releases\n\n' >&2
	printf 'Press Enter to close this pane.' >&2
	read -r _ || true
	exit 127
fi

IFS='
'
set -f
# shellcheck disable=SC2086
set -- ${MADO_REPORT_FILES:-}
set +f
unset IFS

exec mado -watch "$@"
