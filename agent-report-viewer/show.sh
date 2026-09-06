#!/bin/sh
# 明示呼び出しの入口: 指定した markdown を mado の report ペインで開く。
# Claude（やユーザー）がリポジトリ内で `show.sh docs/plan.md` のように呼ぶ。
# イベント駆動の on-agent-done.sh と違い、コミット済みかどうかに関わらず開く。
# herdr の外（HERDR_WORKSPACE_ID 無し）や存在しないファイルは静かに無視する。
set -eu

[ $# -gt 0 ] || exit 0
workspace_id=${HERDR_WORKSPACE_ID:-}
[ -n "$workspace_id" ] || exit 0
command -v mado >/dev/null 2>&1 || exit 0

# state dir はフックと同じ場所を見ないとペインを共有できない。herdr が
# シム経由で渡す HERDR_PLUGIN_STATE_DIR を優先し、直接呼ばれたときは
# herdr の既定配置から求める。
state=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/mado.agent-report-viewer}

# 相対パスは cwd 基準で絶対化し、存在するファイルだけ残す（順序維持）。
files=""
for f in "$@"; do
	case "$f" in
		/*) abs=$f ;;
		*) abs=$PWD/$f ;;
	esac
	[ -f "$abs" ] || continue
	files="${files}${files:+
}$abs"
done
[ -n "$files" ] || exit 0

IFS='
'
set -f
# shellcheck disable=SC2086
set -- $files
set +f
unset IFS
REPORT_WORKSPACE_ID=$workspace_id REPORT_TARGET_PANE=${HERDR_PANE_ID:-} REPORT_CWD=$PWD \
HERDR_PLUGIN_STATE_DIR=$state \
	exec sh "$(dirname "$0")/open-report.sh" "$@"
