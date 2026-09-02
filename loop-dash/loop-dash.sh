#!/bin/sh
# Action entrypoint: フォーカス中のペインの cwd からループ状態ファイルを
# 探し、mado のペインで追従表示する。失敗はすべて「何もしない」に倒す。
set -eu

context=${HERDR_PLUGIN_CONTEXT_JSON:-}
[ -n "$context" ] || exit 0

# 呼び出しコンテキストの文字列フィールドを読む。jq があれば jq、無ければ
# sed フォールバック（herdr は compact JSON を出す前提）。
field() {
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$context" | jq -r --arg key "$1" '.[$key] // empty' 2>/dev/null || printf ''
	else
		printf '%s' "$context" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -1
	fi
}

# フォーカス中のペインの cwd。取れなければワークスペース、それも無ければ PWD。
base=$(field focused_pane_cwd)
[ -n "$base" ] || base=$(field workspace_cwd)
[ -n "$base" ] || base=$PWD
[ -d "$base" ] || exit 0

workspace_id=$(field workspace_id)
[ -n "$workspace_id" ] || exit 0

# 既知名を順に探す。見つかったものを改行区切りで集める。
# single-agent-loop（loop/ 雛形）の状態ファイル。MEMORY が毎周更新される
# 記憶、VISION がゴールと DoD、ARCHITECTURE が VERIFY コマンド、RULES が
# 禁止事項。ループを見張るのに手元に置きたい順に並べる。
files=""
for f in loop/MEMORY.md loop/VISION.md loop/ARCHITECTURE.md loop/RULES.md; do
	if [ -f "$base/$f" ]; then
		files="${files}${files:+
}$base/$f"
	fi
done
[ -n "$files" ] || exit 0

herdr=${HERDR_BIN_PATH:-herdr}
state=${HERDR_PLUGIN_STATE_DIR:-}
[ -n "$state" ] || exit 0
mkdir -p "$state" 2>/dev/null || exit 0
sock="$state/dash-$workspace_id.sock"
record="$state/pane-$workspace_id"

# 記録されたダッシュボードペインが生きていれば、その mado にタブ更新で渡す。
if [ -f "$record" ] && "$herdr" pane get "$(cat "$record")" >/dev/null 2>&1; then
	IFS='
'
	set -f
	# shellcheck disable=SC2086
	set -- $files
	set +f
	unset IFS
	if MADO_SOCKET=$sock mado -remote open "$@" >/dev/null 2>&1; then
		exit 0
	fi
	# ペインは居るが mado がこの socket で応答しない（herdr 再起動でペインが
	# 復元され env が失われた、など）。生きた孤児を残したまま開き直すと
	# 重複するので、先に閉じてから開き直す。
	"$herdr" pane close "$(cat "$record")" >/dev/null 2>&1 || true
fi
rm -f "$record" 2>/dev/null || true

out=$("$herdr" plugin pane open \
	--plugin mado.loop-dash \
	--entrypoint dash \
	--placement split --direction right \
	--cwd "$base" \
	--env "MADO_DASH_FILES=$files" \
	--env "MADO_SOCKET=$sock" \
	--focus 2>/dev/null) || exit 0

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
