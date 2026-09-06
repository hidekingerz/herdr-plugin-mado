#!/bin/sh
# 指定した markdown を、ワークスペースごとに1枚の mado report ペインで開く。
# on-agent-done.sh（イベント駆動）と show.sh（明示呼び出し）の共通部分。
#
# 使い方: open-report.sh <絶対パス…>
# 環境変数:
#   REPORT_WORKSPACE_ID   必須。ペインと socket をこの単位で1つに保つ
#   REPORT_TARGET_PANE    任意。新規ペインをこのペインの右に split する
#   REPORT_CWD            任意。新規ペインの cwd（既定: 先頭ファイルのディレクトリ）
#   HERDR_PLUGIN_STATE_DIR 必須。record と socket の置き場所
#   HERDR_BIN_PATH        任意。herdr CLI（既定: PATH の herdr）
# 失敗はすべて「何もしない・exit 0」に倒す。
set -eu

[ $# -gt 0 ] || exit 0
workspace_id=${REPORT_WORKSPACE_ID:-}
[ -n "$workspace_id" ] || exit 0
state=${HERDR_PLUGIN_STATE_DIR:-}
[ -n "$state" ] || exit 0
herdr=${HERDR_BIN_PATH:-herdr}

mkdir -p "$state" 2>/dev/null || exit 0
sock="$state/report-$workspace_id.sock"
record="$state/pane-$workspace_id"

# 記録された報告ペインがまだ生きていれば、その mado にタブとして渡す。
if [ -f "$record" ] && "$herdr" pane get "$(cat "$record")" >/dev/null 2>&1; then
	if MADO_SOCKET=$sock mado -remote open "$@" >/dev/null 2>&1; then
		exit 0
	fi
	# ペインは居るが mado がこの socket で応答しない（herdr 再起動でペインが
	# 復元され env が失われた、など）。生きた孤児を残したまま開き直すと
	# 重複するので、先に閉じてから開き直す。
	"$herdr" pane close "$(cat "$record")" >/dev/null 2>&1 || true
fi
rm -f "$record" 2>/dev/null || true

# pane.sh へは改行区切りで渡す。
files=""
for f in "$@"; do
	files="${files}${files:+
}$f"
done
cwd=${REPORT_CWD:-$(dirname "$1")}

set -- --plugin mado.agent-report-viewer --entrypoint report
if [ -n "${REPORT_TARGET_PANE:-}" ]; then
	set -- "$@" --target-pane "$REPORT_TARGET_PANE"
fi
out=$("$herdr" plugin pane open "$@" \
	--placement split --direction right \
	--cwd "$cwd" \
	--env "MADO_REPORT_FILES=$files" \
	--env "MADO_SOCKET=$sock" 2>/dev/null) || exit 0

if command -v jq >/dev/null 2>&1; then
	new_pane=$(printf '%s' "$out" | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null) || new_pane=""
else
	new_pane=$(printf '%s' "$out" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' | head -1)
fi
# set -e 下で `[ ... ] && cmd` は条件不成立時にスクリプトごと落とすので if で書く。
if [ -n "$new_pane" ]; then
	printf '%s' "$new_pane" > "$record" 2>/dev/null || true
fi
exit 0
