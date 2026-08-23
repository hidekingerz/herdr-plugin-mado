#!/bin/sh
# Event hook: agent のランが done になったら、そのランが生成した
# markdown を mado のペインで開く。失敗はすべて「何もしない」に倒す。
set -eu

event=${HERDR_PLUGIN_EVENT_JSON:-}
[ -n "$event" ] || exit 0

# エンベロープ {"event":..., "data":{...}} の data 直下のフィールドを読む。
field() {
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$event" | jq -r --arg key "$1" '.data[$key] // empty'
	else
		printf '%s' "$event" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -1
	fi
}

[ "$(field agent_status)" = "done" ] || exit 0

pane_id=$(field pane_id)
workspace_id=$(field workspace_id)
[ -n "$pane_id" ] || exit 0
[ -n "$workspace_id" ] || exit 0

herdr=${HERDR_BIN_PATH:-herdr}

# agent ペインの cwd。取れなければ何もしない。
pane_json=$("$herdr" pane get "$pane_id" 2>/dev/null) || exit 0
if command -v jq >/dev/null 2>&1; then
	cwd=$(printf '%s' "$pane_json" | jq -r '.result.pane.cwd // empty' 2>/dev/null) || cwd=""
else
	cwd=$(printf '%s' "$pane_json" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' | head -1)
fi
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

# ランの成果物 = コミットされていない markdown（変更 + 未追跡）。
git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
changed=$(git -C "$cwd" -c core.quotePath=false status --porcelain -- '*.md' 2>/dev/null \
	| cut -c4- | sed 's/.* -> //') || exit 0
[ -n "$changed" ] || exit 0

# mtime の新しい順に最大4件、絶対パスで。
files=$(printf '%s\n' "$changed" | while IFS= read -r f; do
	[ -f "$cwd/$f" ] || continue
	mtime=$(stat -f %m "$cwd/$f" 2>/dev/null || stat -c %Y "$cwd/$f" 2>/dev/null) || continue
	printf '%s\t%s\n' "$mtime" "$cwd/$f"
done | sort -rn | head -4 | cut -f2-)
[ -n "$files" ] || exit 0

state=${HERDR_PLUGIN_STATE_DIR:-}
[ -n "$state" ] || exit 0
mkdir -p "$state" 2>/dev/null || exit 0
sock="$state/report-$workspace_id.sock"
record="$state/pane-$workspace_id"

# 記録された報告ペインがまだ生きていれば、その mado にタブとして渡す。
if [ -f "$record" ] && "$herdr" pane get "$(cat "$record")" >/dev/null 2>&1; then
	IFS='
'
	# shellcheck disable=SC2086
	set -- $files
	unset IFS
	if MADO_SOCKET=$sock mado -remote open "$@" >/dev/null 2>&1; then
		exit 0
	fi
	# ペインは居るが mado が応答しない: 記録を捨てて開き直す。
fi
rm -f "$record" 2>/dev/null || true

out=$("$herdr" plugin pane open \
	--plugin mado.agent-report-viewer \
	--entrypoint report \
	--target-pane "$pane_id" \
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
