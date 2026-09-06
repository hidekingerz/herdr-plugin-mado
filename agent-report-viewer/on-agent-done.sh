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

# mado が無い環境ではイベント駆動でエラーペインを出さない — 静かに何もしない。
command -v mado >/dev/null 2>&1 || exit 0

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

# ペインへの振り分けは show.sh と共通の open-report.sh に任せる。
IFS='
'
set -f
# shellcheck disable=SC2086
set -- $files
set +f
unset IFS
REPORT_WORKSPACE_ID=$workspace_id REPORT_TARGET_PANE=$pane_id REPORT_CWD=$cwd \
	exec sh "$(dirname "$0")/open-report.sh" "$@"
