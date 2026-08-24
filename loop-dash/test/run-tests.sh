#!/bin/sh
# loop-dash のテスト。実物の herdr / mado の代わりに、呼び出しを記録する
# スタブを PATH に置いて loop-dash.sh を実行し、副作用を検証する。
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0
WORKDIRS=""
trap 'rm -rf $WORKDIRS' EXIT

# ── スタブ環境を組み立てて loop-dash.sh を1回実行する ──
# 使い方: run_action <context-json>
# 前提: new_work 済み。呼び出しは $WORK/calls.log に1行ずつ残る。
run_action() {
	mkdir -p "$WORK/bin" "$WORK/madobin" "$WORK/state"
	cat > "$WORK/bin/herdr" <<-'STUB'
	#!/bin/sh
	# 引数内の改行（MADO_DASH_FILES の改行区切り値など）は `|` に潰して
	# 1呼び出し=1行でログする。テストはこの `|` で改行区切りを検証できる。
	printf 'herdr %s\n' "$(printf '%s' "$*" | tr '\n' '|')" >> "$CALLS"
	case "$1 $2" in
	"pane get")
		# pane-gone マーカーは「記録されたダッシュボードペイン wT:p9」だけを
		# 死んだ扱いにする。
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
	cat > "$WORK/madobin/mado" <<-'STUB'
	#!/bin/sh
	printf 'mado %s MADO_SOCKET=%s\n' "$*" "${MADO_SOCKET:-}" >> "$CALLS"
	exit "${STUB_MADO_EXIT:-0}"
	STUB
	chmod +x "$WORK/bin/herdr" "$WORK/madobin/mado"
	CALLS="$WORK/calls.log"; : > "$CALLS"
	export CALLS STUB_CWD="${STUB_CWD:-$WORK/repo}" STUB_PANE_GONE="$WORK/pane-gone"
	env PATH="$WORK/bin:$WORK/madobin:$PATH" \
		HERDR_BIN_PATH="$WORK/bin/herdr" \
		HERDR_PLUGIN_STATE_DIR="$WORK/state" \
		HERDR_PLUGIN_CONTEXT_JSON="$1" \
		STUB_MADO_EXIT="${STUB_MADO_EXIT:-0}" \
		sh "$ROOT/loop-dash.sh"
	ACTION_EXIT=$?
}

# ── アサーション ──
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
assert_call_grep() { # <pattern> <label>
	grep -q "$1" "$WORK/calls.log" || fail "$2: '$1' が呼ばれていない ($(cat "$WORK/calls.log"))"
}
assert_no_call_grep() { # <pattern> <label>
	grep -q "$1" "$WORK/calls.log" && fail "$2: '$1' が呼ばれてしまった"
}
new_work() { WORK=$(mktemp -d); WORKDIRS="$WORKDIRS $WORK"; }
context_json() { # <cwd>
	printf '{"workspace_id":"wT","workspace_label":"t","workspace_cwd":"%s","tab_id":"wT:t1","focused_pane_id":"wT:p1","focused_pane_cwd":"%s","invocation_source":"cli"}' "$1" "$1"
}

# ── テスト ──

test_no_known_files_does_nothing() {
	new_work
	mkdir -p "$WORK/repo"
	printf 'x\n' > "$WORK/repo/README.md"   # 既知名ではない md だけ
	run_action "$(context_json "$WORK/repo")"
	[ "$ACTION_EXIT" -eq 0 ] || fail "no-files: exit 0 でない ($ACTION_EXIT)"
	assert_no_call_grep "plugin pane open" "no-files"
	assert_no_call_grep "^mado" "no-files"
}

test_opens_dash_with_tasks_md() {
	new_work
	mkdir -p "$WORK/repo"
	printf '%s\n' '- [ ] task' > "$WORK/repo/TASKS.md"
	run_action "$(context_json "$WORK/repo")"
	[ "$ACTION_EXIT" -eq 0 ] || fail "tasks: exit 0 でない ($ACTION_EXIT)"
	assert_call_grep "plugin pane open" "tasks"
	grep "plugin pane open" "$WORK/calls.log" | grep -q "MADO_DASH_FILES=$WORK/repo/TASKS.md" \
		|| fail "tasks: TASKS.md が渡っていない ($(cat "$WORK/calls.log"))"
	assert_call_grep "MADO_SOCKET=" "tasks: socket を env で渡す"
}

test_finds_loop_dir_variants() {
	new_work
	mkdir -p "$WORK/repo/loop"
	printf '%s\n' 'log' > "$WORK/repo/loop/log.md"
	run_action "$(context_json "$WORK/repo")"
	grep "plugin pane open" "$WORK/calls.log" | grep -q "MADO_DASH_FILES=$WORK/repo/loop/log.md" \
		|| fail "loop-dir: loop/log.md が渡っていない ($(cat "$WORK/calls.log"))"
}

test_collects_all_known_names_in_order() {
	new_work
	mkdir -p "$WORK/repo/loop"
	for f in TASKS.md log.md loop/TASKS.md loop/log.md; do
		printf '%s\n' x > "$WORK/repo/$f"
	done
	run_action "$(context_json "$WORK/repo")"
	# 改行はスタブで `|` に潰される。順序ごと検証する。
	grep "plugin pane open" "$WORK/calls.log" \
		| grep -q "MADO_DASH_FILES=$WORK/repo/TASKS.md|$WORK/repo/log.md|$WORK/repo/loop/TASKS.md|$WORK/repo/loop/log.md" \
		|| fail "order: 4件が順序どおりに渡っていない ($(cat "$WORK/calls.log"))"
}

test_new_pane_records_pane_id() {
	new_work
	mkdir -p "$WORK/repo"
	printf '%s\n' x > "$WORK/repo/TASKS.md"
	run_action "$(context_json "$WORK/repo")"
	[ "$(cat "$WORK/state/pane-wT" 2>/dev/null)" = "wT:pR" ] || fail "record: pane id が記録されていない"
}

test_reuses_recorded_pane_via_remote() {
	new_work
	mkdir -p "$WORK/repo" "$WORK/state"
	printf '%s\n' x > "$WORK/repo/TASKS.md"
	printf 'wT:p9' > "$WORK/state/pane-wT"    # 生きているペインの記録あり
	run_action "$(context_json "$WORK/repo")"
	assert_call_grep "mado -remote open" "reuse"
	assert_call_grep "MADO_SOCKET=$WORK/state/dash-wT.sock" "reuse: socket 指定"
	assert_no_call_grep "plugin pane open" "reuse: 新規ペインを開かない"
}

test_stale_record_reopens_pane() {
	new_work
	mkdir -p "$WORK/repo" "$WORK/state"
	printf '%s\n' x > "$WORK/repo/TASKS.md"
	printf 'wT:p9' > "$WORK/state/pane-wT"
	: > "$WORK/pane-gone"                      # herdr スタブが wT:p9 を pane_not_found にする
	run_action "$(context_json "$WORK/repo")"
	assert_call_grep "plugin pane open" "stale: 開き直す"
	[ "$(cat "$WORK/state/pane-wT" 2>/dev/null)" = "wT:pR" ] || fail "stale: 記録が新しいペインに更新されていない"
}

test_remote_failure_reopens_pane() {
	new_work
	mkdir -p "$WORK/repo" "$WORK/state"
	printf '%s\n' x > "$WORK/repo/TASKS.md"
	printf 'wT:p9' > "$WORK/state/pane-wT"
	# `VAR=x func` 形式は POSIX モードの sh で代入が残留するため使わない。
	STUB_MADO_EXIT=1
	run_action "$(context_json "$WORK/repo")"  # mado 死亡を模擬
	unset STUB_MADO_EXIT
	assert_call_grep "plugin pane open" "remote-fail: 開き直す"
}

test_no_known_files_does_nothing
test_opens_dash_with_tasks_md
test_finds_loop_dir_variants
test_collects_all_known_names_in_order
test_new_pane_records_pane_id
test_reuses_recorded_pane_via_remote
test_stale_record_reopens_pane
test_remote_failure_reopens_pane

[ "$FAILED" -eq 0 ] && printf 'ok\n'
exit "$FAILED"
