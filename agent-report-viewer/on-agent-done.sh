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
	cwd=$(printf '%s' "$pane_json" | jq -r '.result.pane.cwd // empty')
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
done | sort -rn | head -4 | cut -f2- | tr '\n' ' ' | sed 's/ $//')
[ -n "$files" ] || exit 0

# ここから先（ペインへ渡す）は Task 3。暫定で新規ペインを開くだけにする。
"$herdr" plugin pane open \
	--plugin mado.agent-report-viewer \
	--entrypoint report \
	--workspace "$workspace_id" \
	--target-pane "$pane_id" \
	--placement split --direction right \
	--cwd "$cwd" \
	--env "MADO_REPORT_FILES=$files" >/dev/null 2>&1 || exit 0
