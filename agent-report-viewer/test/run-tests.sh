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
	printf 'herdr %s\n' "$(printf '%s' "$*" | tr '\n' '|')" >> "$CALLS"
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
	export CALLS STUB_CWD="$WORK/repo" STUB_PANE_GONE="$WORK/pane-gone"
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

# ── ヘルパー ──

# <dir> に使い捨て git リポジトリを作る。引数のファイルを「コミット済み」にする。
scratch_repo() { # <dir> [committed files...]
	dir=$1; shift
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
	for f in "$@"; do
		mkdir -p "$dir/$(dirname "$f")"
		printf 'x\n' > "$dir/$f"
	done
	if [ "$#" -gt 0 ]; then
		git -C "$dir" add -A
		git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m files
	fi
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

test_outside_git_does_nothing() {
	new_work
	mkdir -p "$WORK/repo"     # git init しないただのディレクトリ
	run_hook "$(done_event wT:p1 wT)"
	assert_no_call_grep "plugin pane open" "non-git"
	assert_no_call_grep "^mado" "non-git"
}

test_no_md_changes_does_nothing() {
	new_work
	scratch_repo "$WORK/repo" README.md
	printf 'code\n' > "$WORK/repo/main.go"   # md 以外の未追跡ファイルだけ
	run_hook "$(done_event wT:p1 wT)"
	assert_no_call_grep "plugin pane open" "no-md"
}

test_opens_pane_with_changed_md() {
	new_work
	scratch_repo "$WORK/repo" docs/plan.md
	printf 'edited\n' >> "$WORK/repo/docs/plan.md"    # 変更
	printf 'new\n' > "$WORK/repo/report.md"           # 未追跡
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "plugin pane open" "changed-md"
	assert_call_grep "MADO_REPORT_FILES=" "changed-md: files env"
	grep "plugin pane open" "$WORK/calls.log" | grep -q "docs/plan.md" || fail "changed-md: plan.md が渡っていない"
	grep "plugin pane open" "$WORK/calls.log" | grep -q "report.md" || fail "changed-md: report.md が渡っていない"
	assert_call_grep "\.md|/" "changed-md: files は改行区切り"
}

test_caps_at_four_newest() {
	new_work
	scratch_repo "$WORK/repo"
	for i in 1 2 3 4 5; do
		printf 'r\n' > "$WORK/repo/r$i.md"
		touch -t "2026082300$(printf '%02d' "$i")" "$WORK/repo/r$i.md"
	done
	run_hook "$(done_event wT:p1 wT)"
	line=$(grep "plugin pane open" "$WORK/calls.log" || true)
	case "$line" in *r1.md*) fail "cap: 最も古い r1.md が含まれている";; esac
	for i in 2 3 4 5; do
		case "$line" in *"r$i.md"*) ;; *) fail "cap: r$i.md が落ちている";; esac
	done
}

test_ignores_non_done
test_ignores_empty_event
test_outside_git_does_nothing
test_no_md_changes_does_nothing
test_opens_pane_with_changed_md
test_caps_at_four_newest

[ "$FAILED" -eq 0 ] && printf 'ok\n'
exit "$FAILED"
