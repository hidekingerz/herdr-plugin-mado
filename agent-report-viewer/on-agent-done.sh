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
