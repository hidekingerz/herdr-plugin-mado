#!/bin/sh
# agent-report-viewer のテスト。実物の herdr / mado の代わりに、呼び出しを
# 記録するスタブを PATH に置いて on-agent-done.sh を実行し、副作用を検証する。
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0

# ── スタブ環境を組み立てて on-agent-done.sh を1回実行する ──
# 使い方: run_hook <event-json>
# 前提: $WORK が作成済み。呼び出しは $WORK/calls.log に1行ずつ残る。
run_hook() {
	mkdir -p "$WORK/bin" "$WORK/state"
	cat > "$WORK/bin/herdr" <<-'STUB'
	#!/bin/sh
	printf 'herdr %s\n' "$*" >> "$CALLS"
	case "$1 $2" in
	"pane get")
		# pane-gone マーカーは「記録された報告ペイン wT:p9」だけを死んだ扱いに
		# する。agent ペイン (wT:p1) の cwd 解決まで殺すとテストが成立しない。
		if [ -f "$STUB_PANE_GONE" ] && [ "$3" = "wT:p9" ]; then
			printf '{"error":{"code":"pane_not_found"}}\n'; exit 1
		fi
		printf '{"id":"x","result":{"pane":{"pane_id":"%s","cwd":"%s"}}}\n' "$3" "$STUB_CWD"
		;;
	"plugin pane")
		# 新規に開いたペインは、既存記録 (wT:p9) と区別できる id を返す。
		printf '{"id":"x","result":{"plugin_pane":{"pane":{"pane_id":"wT:pR","cwd":"%s"}}}}\n' "$STUB_CWD"
		;;
	esac
	exit 0
	STUB
	cat > "$WORK/bin/mado" <<-'STUB'
	#!/bin/sh
	printf 'mado %s MADO_SOCKET=%s\n' "$*" "${MADO_SOCKET:-}" >> "$CALLS"
	exit "${STUB_MADO_EXIT:-0}"
	STUB
	chmod +x "$WORK/bin/herdr" "$WORK/bin/mado"
	CALLS="$WORK/calls.log"; : > "$CALLS"
	export CALLS STUB_CWD="${STUB_CWD:-$WORK/repo}" STUB_PANE_GONE="$WORK/pane-gone"
	env PATH="$WORK/bin:$PATH" \
		HERDR_BIN_PATH="$WORK/bin/herdr" \
		HERDR_PLUGIN_STATE_DIR="$WORK/state" \
		HERDR_PLUGIN_EVENT_JSON="$1" \
		STUB_MADO_EXIT="${STUB_MADO_EXIT:-0}" \
		sh "$ROOT/on-agent-done.sh"
	HOOK_EXIT=$?
}

# ── アサーション ──
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
assert_calls_empty() {
	[ -s "$WORK/calls.log" ] && fail "$1: 呼び出しが発生した: $(cat "$WORK/calls.log")"
}
assert_call_grep() { # <pattern> <label>
	grep -q "$1" "$WORK/calls.log" || fail "$2: '$1' が呼ばれていない ($(cat "$WORK/calls.log"))"
}
assert_no_call_grep() { # <pattern> <label>
	grep -q "$1" "$WORK/calls.log" && fail "$2: '$1' が呼ばれてしまった"
}
new_work() { WORK=$(mktemp -d); }
done_event() { # <pane-id> <workspace-id>
	printf '{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"%s","workspace_id":"%s","agent_status":"done","agent":"claude"}}' "$1" "$2"
}

# ── テスト ──

test_ignores_non_done() {
	new_work
	run_hook '{"event":"pane_agent_status_changed","data":{"pane_id":"wT:p1","workspace_id":"wT","agent_status":"working","agent":"claude"}}'
	[ "$HOOK_EXIT" -eq 0 ] || fail "non-done: exit 0 でない ($HOOK_EXIT)"
	assert_calls_empty "non-done"
}

test_ignores_empty_event() {
	new_work
	run_hook ''
	[ "$HOOK_EXIT" -eq 0 ] || fail "empty: exit 0 でない ($HOOK_EXIT)"
	assert_calls_empty "empty"
}

test_ignores_non_done
test_ignores_empty_event

[ "$FAILED" -eq 0 ] && printf 'ok\n'
exit "$FAILED"
