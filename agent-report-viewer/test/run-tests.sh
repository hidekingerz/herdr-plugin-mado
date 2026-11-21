#!/bin/sh
# agent-report-viewer のテスト。実物の herdr / mado の代わりに、呼び出しを
# 記録するスタブを PATH に置いて on-agent-done.sh を実行し、副作用を検証する。
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0

# ── スタブ環境を組み立てて on-agent-done.sh を1回実行する ──
# 使い方: run_hook <event-json>
# 前提: $WORK が作成済み。呼び出しは $WORK/calls.log に1行ずつ残る。
# 内部ヘルパー: スタブ一式を組み立てて on-agent-done.sh を実行する。
# mado スタブは $WORK/bin とは別の $WORK/madobin に置く — PATH から
# madobin を外すだけで「mado が無い環境」を再現できるようにするため。
_make_stubs() {
	mkdir -p "$WORK/bin" "$WORK/madobin" "$WORK/state"
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
	"pane list")
		# 同じワークスペースのペイン一覧。テストが置いた JSON を返す。
		if [ -f "$STUB_PANES" ]; then cat "$STUB_PANES"; else printf '{"id":"x","result":{"panes":[]}}\n'; fi
		;;
	"pane process-info")
		# `pane process-info --pane <id>`: そのペインの前面プロセス。
		if [ -f "$STUB_PROCDIR/$4" ]; then cat "$STUB_PROCDIR/$4"
		else printf '{"id":"x","result":{"process_info":{"foreground_processes":[],"pane_id":"%s"}}}\n' "$4"; fi
		;;
	"plugin pane")
		# pane-open-fail マーカーがあれば herdr がペインを開けなかった状況を再現する。
		if [ -f "$STUB_PANE_OPEN_FAIL" ]; then
			printf '{"error":{"code":"invalid_params"}}\n'; exit 1
		fi
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
	export CALLS STUB_CWD="$WORK/repo" STUB_PANE_GONE="$WORK/pane-gone" STUB_PANE_OPEN_FAIL="$WORK/pane-open-fail"
	# mado のソケット置き場は必ず $WORK の中を見させる（開発機で動いている本物の
	# mado のソケットを拾わないように）。
	mkdir -p "$WORK/run/mado" "$WORK/tmp" "$WORK/proc"
	export STUB_PANES="$WORK/panes.json" STUB_PROCDIR="$WORK/proc" XDG_RUNTIME_DIR="$WORK/run" TMPDIR="$WORK/tmp"
}

_run_hook_common() { # <path-value> <event-json>
	_make_stubs
	env PATH="$1" \
		HERDR_BIN_PATH="$WORK/bin/herdr" \
		HERDR_PLUGIN_STATE_DIR="$WORK/state" \
		HERDR_PLUGIN_EVENT_JSON="$2" \
		STUB_MADO_EXIT="${STUB_MADO_EXIT:-0}" \
		sh "$ROOT/on-agent-done.sh"
	HOOK_EXIT=$?
}

# 使い方: run_show [--no-herdr] <file…>
# $WORK/repo を cwd にして show.sh を実行する（Claude がリポジトリ内で呼ぶ想定）。
# --no-herdr は HERDR_WORKSPACE_ID 無し＝herdr の外から呼ばれた状況を再現する。
run_show() {
	_make_stubs
	ws=wT
	if [ "${1:-}" = "--no-herdr" ]; then ws=""; shift; fi
	( cd "$WORK/repo" && env PATH="$WORK/bin:$WORK/madobin:$PATH" \
		HERDR_BIN_PATH="$WORK/bin/herdr" \
		HERDR_PLUGIN_STATE_DIR="$WORK/state" \
		HERDR_WORKSPACE_ID="$ws" \
		HERDR_PANE_ID="wT:p1" \
		STUB_MADO_EXIT="${STUB_MADO_EXIT:-0}" \
		sh "$ROOT/show.sh" "$@" )
	SHOW_EXIT=$?
}

# 使い方: run_hook <event-json>
# 前提: $WORK が作成済み。呼び出しは $WORK/calls.log に1行ずつ残る。
run_hook() {
	_run_hook_common "$WORK/bin:$WORK/madobin:$PATH" "$1"
}

# run_hook と同じだが mado スタブを PATH から外す。加えて $PATH をそのまま
# 継ぎ足すと開発機に homebrew 等でインストール済みの本物の mado が拾われて
# しまう（実際に踏んだ）ので、標準の system ディレクトリだけに絞った PATH
# で起動する ("mado が無い環境")。sh / git / sed / sort 等は /usr/bin,
# /bin に入っているので動作に支障は無い（jq が無くても field() は sed に
# フォールバックする）。
run_hook_no_mado() {
	_run_hook_common "$WORK/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$1"
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

test_reuses_recorded_pane_via_remote() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	mkdir -p "$WORK/state"
	printf 'wT:p9' > "$WORK/state/pane-wT"    # 生きているペインの記録あり
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "mado -remote open" "reuse"
	assert_call_grep "MADO_SOCKET=$WORK/state/report-wT.sock" "reuse: socket 指定"
	assert_no_call_grep "plugin pane open" "reuse: 新規ペインを開かない"
}

test_stale_record_reopens_pane() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	mkdir -p "$WORK/state"
	printf 'wT:p9' > "$WORK/state/pane-wT"
	: > "$WORK/pane-gone"                      # herdr スタブが wT:p9 を pane_not_found にする
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "plugin pane open" "stale: 開き直す"
	assert_call_grep "MADO_SOCKET=" "stale: socket を env で渡す"
	[ "$(cat "$WORK/state/pane-wT" 2>/dev/null)" = "wT:pR" ] || fail "stale: 記録が新しいペインに更新されていない"
}

test_remote_failure_reopens_pane() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	mkdir -p "$WORK/state"
	printf 'wT:p9' > "$WORK/state/pane-wT"
	# 注意: `VAR=x func` 形式は POSIX モードの sh では関数呼び出し後も代入が
	# 残留するため使わない。明示的に set / unset する。
	STUB_MADO_EXIT=1
	run_hook "$(done_event wT:p1 wT)"                    # mado 死亡を模擬
	unset STUB_MADO_EXIT
	assert_call_grep "plugin pane open" "remote-fail: 開き直す"
	# 生きている孤児ペインを残したまま開き直すと重複する。閉じてから開くこと。
	assert_call_grep "pane close wT:p9" "remote-fail: 旧ペインを閉じる"
}

test_new_pane_records_pane_id() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	run_hook "$(done_event wT:p1 wT)"
	[ "$(cat "$WORK/state/pane-wT" 2>/dev/null)" = "wT:pR" ] || fail "record: pane id が記録されていない"
}

test_missing_mado_does_nothing() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	run_hook_no_mado "$(done_event wT:p1 wT)"
	[ "$HOOK_EXIT" -eq 0 ] || fail "no-mado: exit 0 でない ($HOOK_EXIT)"
	assert_no_call_grep "plugin pane open" "no-mado"
}

test_ignores_non_done
test_ignores_empty_event
test_outside_git_does_nothing
test_no_md_changes_does_nothing
test_opens_pane_with_changed_md
test_caps_at_four_newest
test_reuses_recorded_pane_via_remote
test_stale_record_reopens_pane
test_remote_failure_reopens_pane
test_new_pane_records_pane_id
test_missing_mado_does_nothing

# ── 通知（ペインを開いた／タブを追加したら herdr notification show）──

test_new_pane_notifies_with_filenames() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	printf 'p\n' > "$WORK/repo/plan.md"
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "notification show" "notify-new"
	line=$(grep "notification show" "$WORK/calls.log" || true)
	case "$line" in *report.md*) ;; *) fail "notify-new: 本文に report.md が無い ($line)";; esac
	case "$line" in *plan.md*) ;; *) fail "notify-new: 本文に plan.md が無い ($line)";; esac
	case "$line" in *"$WORK/repo/"*) fail "notify-new: 本文にディレクトリが混ざっている ($line)";; esac
}

test_reuse_notifies() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	mkdir -p "$WORK/state"; printf 'wT:p9' > "$WORK/state/pane-wT"
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "mado -remote open" "notify-reuse: 再利用経路"
	assert_call_grep "notification show" "notify-reuse"
}

test_failed_pane_open_does_not_notify() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	: > "$WORK/pane-open-fail"
	run_hook "$(done_event wT:p1 wT)"
	[ "$HOOK_EXIT" -eq 0 ] || fail "notify-fail: exit 0 でない ($HOOK_EXIT)"
	assert_call_grep "plugin pane open" "notify-fail: open は試みる"
	assert_no_call_grep "notification show" "notify-fail: 開けなかったのに通知した"
}

# ── show.sh（明示呼び出し）──

test_show_opens_given_files() {
	new_work
	mkdir -p "$WORK/repo/docs"
	printf 'p\n' > "$WORK/repo/docs/plan.md"
	printf 'r\n' > "$WORK/repo/report.md"
	run_show docs/plan.md "$WORK/repo/report.md"      # 相対と絶対を混ぜる
	[ "$SHOW_EXIT" -eq 0 ] || fail "show: exit 0 でない ($SHOW_EXIT)"
	assert_call_grep "plugin pane open" "show"
	assert_call_grep "MADO_REPORT_FILES=$WORK/repo/docs/plan.md|$WORK/repo/report.md" "show: 相対→絶対・順序維持"
	assert_call_grep "target-pane wT:p1" "show: 呼び出し元ペインの右に開く"
	[ "$(cat "$WORK/state/pane-wT" 2>/dev/null)" = "wT:pR" ] || fail "show: record が記録されていない"
}

test_show_outside_herdr_does_nothing() {
	new_work
	mkdir -p "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	run_show --no-herdr report.md
	[ "$SHOW_EXIT" -eq 0 ] || fail "show-no-herdr: exit 0 でない ($SHOW_EXIT)"
	assert_calls_empty "show-no-herdr"
}

test_show_skips_missing_files() {
	new_work
	mkdir -p "$WORK/repo"
	run_show nope.md
	[ "$SHOW_EXIT" -eq 0 ] || fail "show-missing: exit 0 でない ($SHOW_EXIT)"
	assert_no_call_grep "plugin pane open" "show-missing"
}

test_show_reuses_recorded_pane() {
	new_work
	mkdir -p "$WORK/repo" "$WORK/state"
	printf 'r\n' > "$WORK/repo/report.md"
	printf 'wT:p9' > "$WORK/state/pane-wT"    # 生きているペインの記録あり
	run_show report.md
	assert_call_grep "mado -remote open $WORK/repo/report.md" "show-reuse"
	assert_no_call_grep "plugin pane open" "show-reuse: 新規ペインを開かない"
}

# ── install-cli（config dir にシムを書く）──

test_install_cli_writes_shim() {
	new_work
	mkdir -p "$WORK/cfg"
	env HERDR_PLUGIN_ROOT="$ROOT" HERDR_PLUGIN_CONFIG_DIR="$WORK/cfg" \
		HERDR_PLUGIN_STATE_DIR="$WORK/state" HERDR_BIN_PATH="$WORK/bin/herdr" \
		sh "$ROOT/install-cli.sh" >/dev/null 2>&1
	[ -x "$WORK/cfg/show" ] || fail "install-cli: 実行可能な shim $WORK/cfg/show が無い"
	grep -q "$ROOT/show.sh" "$WORK/cfg/show" 2>/dev/null \
		|| fail "install-cli: shim がプラグインルートの show.sh を指していない"
	grep -q "HERDR_PLUGIN_STATE_DIR=" "$WORK/cfg/show" 2>/dev/null \
		|| fail "install-cli: shim に state dir が焼き込まれていない"
}

test_new_pane_notifies_with_filenames
test_reuse_notifies
test_failed_pane_open_does_not_notify
test_show_opens_given_files
test_show_outside_herdr_does_nothing
test_show_skips_missing_files
test_show_reuses_recorded_pane
test_install_cli_writes_shim

# ── ランの範囲（working で開始時刻を記録し、done ではそのラン中に触った md だけ開く）──

status_event() { # <status>
	printf '{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"wT:p1","workspace_id":"wT","agent_status":"%s","agent":"claude"}}' "$1"
}
# ラン開始より前に書かれた md を再現する（mtime を過去にする）。
stale() { touch -t 202601010000 "$@"; }
commit_all() {
	git -C "$WORK/repo" add -A
	git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q -m run
}

test_run_ignores_md_written_before_it() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'old\n' > "$WORK/repo/notes.md"; stale "$WORK/repo/notes.md"
	run_hook "$(status_event working)"
	printf 'code\n' > "$WORK/repo/main.go"       # このランはコードしか触らない
	run_hook "$(status_event done)"
	assert_no_call_grep "plugin pane open" "run-stale: 前から残っている md で開いた"
	assert_no_call_grep "^mado" "run-stale"
	assert_no_call_grep "notification show" "run-stale: 通知した"
}

test_run_opens_only_md_written_in_it() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'old\n' > "$WORK/repo/notes.md"; stale "$WORK/repo/notes.md"
	run_hook "$(status_event working)"
	printf 'new\n' > "$WORK/repo/plan.md"
	run_hook "$(status_event done)"
	line=$(grep "plugin pane open" "$WORK/calls.log" || true)
	case "$line" in *plan.md*) ;; *) fail "run-new: ラン中に書いた plan.md が開かれていない ($line)";; esac
	case "$line" in *notes.md*) fail "run-new: 前から残っている notes.md まで開いた";; esac
}

test_run_opens_md_committed_in_it() {
	new_work
	scratch_repo "$WORK/repo"
	run_hook "$(status_event working)"
	printf 'plan\n' > "$WORK/repo/plan.md"
	commit_all                                    # 同じランの中でコミットまで済ませた
	run_hook "$(status_event done)"
	line=$(grep "plugin pane open" "$WORK/calls.log" || true)
	case "$line" in *plan.md*) ;; *) fail "run-committed: コミット済みの plan.md が開かれていない ($line)";; esac
}

test_run_start_survives_blocked_and_resume() {
	new_work
	scratch_repo "$WORK/repo"
	run_hook "$(status_event working)"
	printf 'plan\n' > "$WORK/repo/plan.md"
	sleep 1                                       # 再開時刻が plan.md の mtime を追い越すように
	run_hook "$(status_event blocked)"            # 承認待ち
	run_hook "$(status_event working)"            # 再開。開始時刻を上書きしてはいけない
	run_hook "$(status_event done)"
	line=$(grep "plugin pane open" "$WORK/calls.log" || true)
	case "$line" in *plan.md*) ;; *) fail "run-blocked: 承認待ちの前に書いた plan.md が落ちた ($line)";; esac
}

test_next_run_starts_fresh() {
	new_work
	scratch_repo "$WORK/repo"
	run_hook "$(status_event working)"
	printf 'plan\n' > "$WORK/repo/plan.md"
	run_hook "$(status_event done)"               # 1ラン目: plan.md を開く
	stale "$WORK/repo/plan.md"                    # 時間が経った、を再現
	run_hook "$(status_event working)"
	run_hook "$(status_event done)"               # 2ラン目は md を触っていない
	assert_no_call_grep "plugin pane open" "run-fresh: 前のランの md をまた開いた"
	assert_no_call_grep "^mado" "run-fresh: 前のランの md をまたタブに送った"
}

test_done_without_start_uses_previous_done() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'old\n' > "$WORK/repo/notes.md"; stale "$WORK/repo/notes.md"
	run_hook "$(status_event done)"               # 開始を見ていない初回: 従来どおり開く
	assert_call_grep "plugin pane open" "prev-done: 基準が無い初回は従来どおり開く"
	run_hook "$(status_event done)"               # 2回目: 前回 done 以降に触った md は無い
	assert_no_call_grep "plugin pane open" "prev-done: 触っていない md でまた開いた"
	assert_no_call_grep "^mado" "prev-done: 触っていない md をまたタブに送った"
}

# ── パスの扱い ──

test_subdir_cwd_resolves_from_repo_root() {
	new_work
	scratch_repo "$WORK/repo" top.md pkg/api/README.md
	printf 'e\n' >> "$WORK/repo/top.md"
	printf 'e\n' >> "$WORK/repo/pkg/api/README.md"
	_make_stubs
	STUB_CWD="$WORK/repo/pkg/api"                 # agent ペインはサブディレクトリに居る
	env PATH="$WORK/bin:$WORK/madobin:$PATH" HERDR_BIN_PATH="$WORK/bin/herdr" \
		HERDR_PLUGIN_STATE_DIR="$WORK/state" HERDR_PLUGIN_EVENT_JSON="$(status_event done)" \
		sh "$ROOT/on-agent-done.sh"
	line=$(grep "plugin pane open" "$WORK/calls.log" || true)
	case "$line" in *"$WORK/repo/pkg/api/README.md"*) ;; *) fail "subdir: pkg/api/README.md が正しいパスで開かれていない ($line)";; esac
	case "$line" in *"$WORK/repo/top.md"*) ;; *) fail "subdir: リポジトリ直下の top.md が開かれていない ($line)";; esac
}

test_filename_with_space_opens() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'p\n' > "$WORK/repo/my plan.md"
	run_hook "$(status_event done)"
	assert_call_grep "MADO_REPORT_FILES=$WORK/repo/my plan.md" "space: 空白入りファイル名が開かれていない"
}

test_staged_md_opens() {
	new_work
	scratch_repo "$WORK/repo" a.md
	git -C "$WORK/repo" mv a.md b.md              # ステージ済みのリネーム
	printf 'n\n' > "$WORK/repo/c.md"; git -C "$WORK/repo" add c.md
	run_hook "$(status_event done)"
	line=$(grep "plugin pane open" "$WORK/calls.log" || true)
	case "$line" in *b.md*) ;; *) fail "staged: リネーム後の b.md が開かれていない ($line)";; esac
	case "$line" in *c.md*) ;; *) fail "staged: add 済みの c.md が開かれていない ($line)";; esac
}

test_run_ignores_md_written_before_it
test_run_opens_only_md_written_in_it
test_run_opens_md_committed_in_it
test_run_start_survives_blocked_and_resume
test_next_run_starts_fresh
test_done_without_start_uses_previous_done
test_subdir_cwd_resolves_from_repo_root
test_filename_with_space_opens
test_staged_md_opens

# ── 既に動いている mado の再利用（report ペインが無いとき、同じタブの mado にタブを足す）──

# ワークスペース wT のペイン一覧を置く。引数は "<pane-id> <tab-id>" を1ペインずつ。
# herdr の実出力と同じくキーはアルファベット順で、pane_id と tab_id の間に入れ子の
# オブジェクト (scroll) が挟まる。
set_panes() {
	sep=""; body=""
	for pt in "$@"; do
		set -f; set -- $pt "$@"; set +f       # $1=pane $2=tab（以降は元の引数）
		body="$body$sep{\"agent_status\":\"unknown\",\"cwd\":\"/x\",\"pane_id\":\"$1\",\"revision\":0,\"scroll\":{\"viewport_rows\":68},\"tab_id\":\"$2\",\"workspace_id\":\"wT\"}"
		sep=","; shift 2
	done
	printf '{"id":"x","result":{"panes":[%s]}}\n' "$body" > "$WORK/panes.json"
}
# <pane-id> で mado が pid <pid> で動いていることにする。--no-socket を付けると
# pid 名のソケットを置かない（MADO_SOCKET 指定で起動した mado の再現）。
# pid は実在しえない大きさにして、本物のソケットと偶然一致しないようにする。
MADO_PID=4242424
user_mado() { # <pane-id> [--no-socket]
	mkdir -p "$WORK/proc" "$WORK/run/mado"
	printf '{"id":"x","result":{"process_info":{"foreground_process_group_id":%s,"foreground_processes":[{"argv":["mado","notes.md"],"argv0":"mado","cmdline":"mado notes.md","cwd":"/x","name":"mado","pid":%s}],"pane_id":"%s","shell_pid":4000}}}\n' \
		"$MADO_PID" "$MADO_PID" "$1" > "$WORK/proc/$1"
	[ "${2:-}" = "--no-socket" ] || : > "$WORK/run/mado/$MADO_PID.sock"
}
# report.md を1つ未コミットで持つリポジトリを用意する。
repo_with_report() {
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
}
# jq を隠した PATH（sed / grep のフォールバック経路を通す）。システムの
# /usr/bin に jq が入っている環境があるので、必要な道具だけ並べた場所を作る。
nojq_path() {
	mkdir -p "$WORK/nojq"
	for t in sh git sed grep awk head cut sort stat date tr cat rm mkdir dirname basename id; do
		p=$(command -v "$t") && ln -sf "$p" "$WORK/nojq/$t"
	done
	printf '%s' "$WORK/bin:$WORK/madobin:$WORK/nojq"
}

test_adopts_user_mado_in_same_tab() {
	new_work
	repo_with_report
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t1"
	user_mado wT:p2
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "mado -remote open $WORK/repo/report.md MADO_SOCKET=$WORK/run/mado/$MADO_PID.sock" "adopt: 既存の mado に送られていない"
	assert_no_call_grep "plugin pane open" "adopt: 既存の mado が居るのに新しいペインを開いた"
	assert_call_grep "notification show" "adopt: 通知が無い"
	[ ! -f "$WORK/state/pane-wT" ] || fail "adopt: ユーザーのペインを report ペインとして記録した"
}

test_adopts_user_mado_without_jq() {
	new_work
	repo_with_report
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t1"
	user_mado wT:p2
	_run_hook_common "$(nojq_path)" "$(done_event wT:p1 wT)"
	assert_call_grep "mado -remote open $WORK/repo/report.md MADO_SOCKET=$WORK/run/mado/$MADO_PID.sock" "adopt-nojq: 既存の mado に送られていない"
	assert_no_call_grep "plugin pane open" "adopt-nojq: 新しいペインを開いた"
}

test_ignores_user_mado_in_other_tab() {
	new_work
	repo_with_report
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t2"         # mado は別タブ（見えていない）
	user_mado wT:p2
	run_hook "$(done_event wT:p1 wT)"
	assert_no_call_grep "mado -remote" "other-tab: 見えていないタブの mado に送った"
	assert_call_grep "plugin pane open" "other-tab: 新しいペインを開いていない"
}

test_ignores_mado_without_pid_socket() {
	new_work
	repo_with_report
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t1"
	user_mado wT:p2 --no-socket                   # loop-dash のように専用ソケットの mado
	run_hook "$(done_event wT:p1 wT)"
	assert_no_call_grep "mado -remote" "no-sock: 送り先のソケットが無いのに送った"
	assert_call_grep "plugin pane open" "no-sock: 新しいペインを開いていない"
}

test_adoption_failure_opens_pane_and_keeps_user_pane() {
	new_work
	repo_with_report
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t1"
	user_mado wT:p2
	STUB_MADO_EXIT=1
	run_hook "$(done_event wT:p1 wT)"             # 既存の mado が応答しない
	unset STUB_MADO_EXIT
	assert_call_grep "plugin pane open" "adopt-fail: 新しいペインに倒れていない"
	assert_no_call_grep "pane close" "adopt-fail: ユーザーのペインを閉じた"
}

test_recorded_report_pane_wins_over_user_mado() {
	new_work
	repo_with_report
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t1" "wT:p9 wT:t1"
	user_mado wT:p2
	mkdir -p "$WORK/state"; printf 'wT:p9' > "$WORK/state/pane-wT"    # report ペインが既にある
	run_hook "$(done_event wT:p1 wT)"
	assert_call_grep "MADO_SOCKET=$WORK/state/report-wT.sock" "report-wins: report ペインに送られていない"
	assert_no_call_grep "MADO_SOCKET=$WORK/run/mado" "report-wins: ユーザーの mado にも送った"
}

test_show_adopts_user_mado() {
	new_work
	mkdir -p "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	set_panes "wT:p1 wT:t1" "wT:p2 wT:t1"
	user_mado wT:p2
	run_show report.md
	assert_call_grep "mado -remote open $WORK/repo/report.md MADO_SOCKET=$WORK/run/mado/$MADO_PID.sock" "show-adopt: 既存の mado に送られていない"
	assert_no_call_grep "plugin pane open" "show-adopt: 新しいペインを開いた"
}

test_adopts_user_mado_in_same_tab
test_adopts_user_mado_without_jq
test_ignores_user_mado_in_other_tab
test_ignores_mado_without_pid_socket
test_adoption_failure_opens_pane_and_keeps_user_pane
test_recorded_report_pane_wins_over_user_mado
test_show_adopts_user_mado

[ "$FAILED" -eq 0 ] && printf 'ok\n'
exit "$FAILED"
