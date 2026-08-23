# agent-report-viewer 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** agent のランが done になったとき、そのランが生成した markdown を mado で自動表示する herdr プラグイン `mado.agent-report-viewer` を作る。

**Architecture:** herdr の `[[events]]` で `pane.agent_status_changed` を購読し、`done` のときに agent ペインの cwd の git 差分から `*.md` を検出、ワークスペースごとに1枚の mado ペインへ渡す。ペインの mado は `MADO_SOCKET` を固定して起動し、2回目以降は `mado -remote open` でタブ追加する。全ファイル POSIX シェル、デーモン無し。

**Tech Stack:** POSIX sh / herdr 0.8.0+ の plugin API（CLI 経由）/ mado v1.2.0+（`-remote`, `-watch`, `MADO_SOCKET`）/ git

**Spec:** `docs/superpowers/specs/2026-08-23-agent-report-viewer-design.md`

## Global Constraints

- herdr 0.8.0 以上（`min_herdr_version = "0.8.0"`）、mado v1.2.0 以上が `PATH` にあること。
- POSIX sh のみ（bash 拡張禁止）。Linux / macOS 両対応（`stat` は BSD/GNU 両形式をフォールバック）。
- イベントフックのあらゆる失敗は「何もしない・exit 0」に倒す。ユーザーにエラーを見せない。
- エントリポイントは必ず `$HERDR_PLUGIN_ROOT` 経由で参照する（herdr はプラグインコマンドをプラグインルートで実行しない）。
- `jq` はあれば使い、無ければ sed フォールバック（docs-peek と同じ方針。herdr は compact JSON を出す前提）。

## 事前検証で確定した事実（計画の前提）

1. マニフェストのイベント名は**ドット区切り** `pane.agent_status_changed`。`pane_agent_status_changed`（アンダースコア）では発火しない（検証済み）。
2. `HERDR_PLUGIN_EVENT_JSON` はエンベロープ形式：`{"event":"pane_agent_status_changed","data":{"type":...,"pane_id":"wG:pF","workspace_id":"wG","agent_status":"working","agent":"claude"}}`。フィールドは `.data` の下。
3. mado の remote ソケットは `MADO_SOCKET` 環境変数で固定できる。listen 側（`remote.DefaultPath`）も send 側（`remote.Send` の `candidates`）も同じ変数を最優先する。未指定の send は全インスタンスを新しい順に試すため宛先が曖昧 → **本プラグインは常に `MADO_SOCKET` を明示する**。
4. `herdr pane report-agent` の `--state` に `done` は無い（idle/working/blocked/unknown のみ）。`done` は herdr が実 agent の完了時に導出する。E2E 検証は実 agent ラン（このリポジトリで動く Claude 等）で行う。`done` の重複発火の有無は Task 5 で実イベントログ（デバッグ用 `debug.evtdump` プラグインが `~/.local/state/herdr/plugins/debug.evtdump/events.log` に収集中）を確認する。

## File Structure

| ファイル | 責務 |
| -------- | ---- |
| `agent-report-viewer/herdr-plugin.toml` | マニフェスト：イベント購読・pane エントリポイント宣言 |
| `agent-report-viewer/on-agent-done.sh` | イベントフック本体：done 判定 → md 検出 → ペイン再利用 or 新規 |
| `agent-report-viewer/pane.sh` | ペインエントリポイント：`MADO_REPORT_FILES` のファイルで mado 起動 |
| `agent-report-viewer/test/run-tests.sh` | テストハーネス：herdr/mado スタブ + 使い捨て git リポジトリで on-agent-done.sh を検証 |

---

### Task 1: テストハーネスと「done 以外では何もしない」

**Files:**
- Create: `agent-report-viewer/test/run-tests.sh`
- Create: `agent-report-viewer/on-agent-done.sh`

**Interfaces:**
- Produces: `run-tests.sh` — 引数なしで全テストを実行し、失敗があれば exit 1。ヘルパー `run_hook <event-json>`（スタブ環境で on-agent-done.sh を実行し、スタブへの呼び出しを `$WORK/calls.log` に記録する）。以後のタスクはこのハーネスにテストケース関数を追加していく。
- Produces: `on-agent-done.sh` — `HERDR_PLUGIN_EVENT_JSON` を読み、`data.agent_status` が `done` 以外なら何もせず exit 0。

- [ ] **Step 1: ハーネスと失敗するテストを書く**

`agent-report-viewer/test/run-tests.sh` を以下の内容で作成する：

```sh
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
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `sh agent-report-viewer/test/run-tests.sh`
Expected: `on-agent-done.sh` が存在しないため FAIL（`sh: .../on-agent-done.sh: No such file` → exit code 非0 で fail が出る。ハーネス自体のエラーで止まる場合も「まだ実装が無いから失敗」であれば良い）

- [ ] **Step 3: 最小実装を書く**

`agent-report-viewer/on-agent-done.sh` を以下の内容で作成する：

```sh
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
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `sh agent-report-viewer/test/run-tests.sh`
Expected: `ok`

- [ ] **Step 5: コミット**

```bash
git add agent-report-viewer/on-agent-done.sh agent-report-viewer/test/run-tests.sh
git commit -m "agent-report-viewer: add test harness and done-only gate"
```

---

### Task 2: git 差分からの markdown 検出

**Files:**
- Modify: `agent-report-viewer/on-agent-done.sh`（末尾に追記）
- Modify: `agent-report-viewer/test/run-tests.sh`（テスト追加）

**Interfaces:**
- Consumes: Task 1 の `field`、`run_hook`、`done_event`、アサーション群。
- Produces: on-agent-done.sh のシェル変数 — `pane_id`、`workspace_id`、`cwd`（agent ペインの作業ディレクトリ）、`files`（改行区切り・絶対パス・mtime 降順・最大4件の markdown）。候補0件はここで exit 0。Task 3 はこの変数群の続きに実装を足す。

- [ ] **Step 1: 失敗するテストを追加する**

`run-tests.sh` の `test_ignores_non_done` の定義より前に追加する：

```sh
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
```

テスト関数を追加し、既存の呼び出し行の並びに追記する：

```sh
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

test_outside_git_does_nothing
test_no_md_changes_does_nothing
test_opens_pane_with_changed_md
test_caps_at_four_newest
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `sh agent-report-viewer/test/run-tests.sh`
Expected: `changed-md` と `cap` 系が FAIL（`plugin pane open` がまだ呼ばれないため）。`non-git` / `no-md` は実装前でも通る（何もしないから）。

- [ ] **Step 3: 検出ロジックを実装する**

`on-agent-done.sh` の末尾に追記する：

```sh
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
done | sort -rn | head -4 | cut -f2-)
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
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `sh agent-report-viewer/test/run-tests.sh`
Expected: `ok`

- [ ] **Step 5: コミット**

```bash
git add agent-report-viewer/on-agent-done.sh agent-report-viewer/test/run-tests.sh
git commit -m "agent-report-viewer: detect uncommitted markdown via git status"
```

---

### Task 3: ペイン再利用と MADO_SOCKET

**Files:**
- Modify: `agent-report-viewer/on-agent-done.sh`（Task 2 の暫定 pane open 部分を置き換え）
- Modify: `agent-report-viewer/test/run-tests.sh`（テスト追加）

**Interfaces:**
- Consumes: Task 2 の `files` / `cwd` / `workspace_id` / `pane_id` / `herdr` 変数、テストの `scratch_repo` / `done_event`。
- Produces: 状態ファイル規約 — `$HERDR_PLUGIN_STATE_DIR/pane-<workspace_id>`（記録された報告ペインの pane_id）と `$HERDR_PLUGIN_STATE_DIR/report-<workspace_id>.sock`（そのワークスペースの mado の `MADO_SOCKET`）。Task 4 の pane.sh はこの `MADO_SOCKET` を継承して mado を起動する。

- [ ] **Step 1: 失敗するテストを追加する**

`run-tests.sh` にテスト関数を追加し、呼び出し行も追記する：

```sh
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
}

test_new_pane_records_pane_id() {
	new_work
	scratch_repo "$WORK/repo"
	printf 'r\n' > "$WORK/repo/report.md"
	run_hook "$(done_event wT:p1 wT)"
	[ "$(cat "$WORK/state/pane-wT" 2>/dev/null)" = "wT:pR" ] || fail "record: pane id が記録されていない"
}

test_reuses_recorded_pane_via_remote
test_stale_record_reopens_pane
test_remote_failure_reopens_pane
test_new_pane_records_pane_id
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `sh agent-report-viewer/test/run-tests.sh`
Expected: `reuse` / `record` 系が FAIL（`mado -remote` も記録もまだ無い）。

- [ ] **Step 3: 再利用ロジックを実装する**

`on-agent-done.sh` の Task 2 で入れた「暫定で新規ペインを開くだけ」のブロック（`"$herdr" plugin pane open` の呼び出し）を、以下に**置き換える**：

```sh
state=${HERDR_PLUGIN_STATE_DIR:-}
[ -n "$state" ] || exit 0
mkdir -p "$state"
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
rm -f "$record"

out=$("$herdr" plugin pane open \
	--plugin mado.agent-report-viewer \
	--entrypoint report \
	--workspace "$workspace_id" \
	--target-pane "$pane_id" \
	--placement split --direction right \
	--cwd "$cwd" \
	--env "MADO_REPORT_FILES=$files" \
	--env "MADO_SOCKET=$sock" 2>/dev/null) || exit 0

if command -v jq >/dev/null 2>&1; then
	new_pane=$(printf '%s' "$out" | jq -r '.result.plugin_pane.pane.pane_id // empty')
else
	new_pane=$(printf '%s' "$out" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' | head -1)
fi
# set -e 下で `[ ... ] && cmd` は条件不成立時にスクリプトごと落とすので if で書く。
if [ -n "$new_pane" ]; then
	printf '%s' "$new_pane" > "$record"
fi
exit 0
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `sh agent-report-viewer/test/run-tests.sh`
Expected: `ok`（Task 1〜3 の全テスト）

- [ ] **Step 5: コミット**

```bash
git add agent-report-viewer/on-agent-done.sh agent-report-viewer/test/run-tests.sh
git commit -m "agent-report-viewer: reuse one report pane per workspace via MADO_SOCKET"
```

---

### Task 4: pane.sh とマニフェスト

**Files:**
- Create: `agent-report-viewer/pane.sh`
- Create: `agent-report-viewer/herdr-plugin.toml`

**Interfaces:**
- Consumes: Task 3 の規約 — `MADO_REPORT_FILES`（改行区切り絶対パス）と `MADO_SOCKET`（環境変数として herdr がペインプロセスへ渡す）。
- Produces: プラグイン id `mado.agent-report-viewer`、pane エントリポイント `report`。

- [ ] **Step 1: pane.sh を書く**

`agent-report-viewer/pane.sh` を以下の内容で作成する：

```sh
#!/bin/sh
# Pane entrypoint: ランが生成した markdown を mado で開く。
# MADO_REPORT_FILES: 改行区切りの絶対パス。MADO_SOCKET: remote 用ソケット
# （herdr が --env で渡し、この mado が listen し、以後のフックが送り先にする）。
set -eu

if ! command -v mado >/dev/null 2>&1; then
	printf 'mado is not on PATH.\n\n' >&2
	printf 'Install it with:  go install github.com/hidekingerz/mado@latest\n' >&2
	printf 'or from https://github.com/hidekingerz/mado/releases\n\n' >&2
	printf 'Press Enter to close this pane.' >&2
	read -r _ || true
	exit 127
fi

IFS='
'
# shellcheck disable=SC2086
set -- ${MADO_REPORT_FILES:-}
unset IFS

exec mado -watch "$@"
```

- [ ] **Step 2: マニフェストを書く**

`agent-report-viewer/herdr-plugin.toml` を以下の内容で作成する：

```toml
id = "mado.agent-report-viewer"
name = "mado agent report viewer"
version = "0.1.0"
min_herdr_version = "0.8.0"
description = "Show the markdown an agent run produced, in mado, when the run is done."
platforms = ["linux", "macos"]

[[events]]
on = "pane.agent_status_changed"
command = ["sh", "-c", "exec sh \"$HERDR_PLUGIN_ROOT/on-agent-done.sh\""]

[[panes]]
id = "report"
title = "mado report"
placement = "split"
command = ["sh", "-c", "exec sh \"$HERDR_PLUGIN_ROOT/pane.sh\""]
```

- [ ] **Step 3: 全テストと lint 相当の確認**

Run: `sh agent-report-viewer/test/run-tests.sh && sh -n agent-report-viewer/on-agent-done.sh && sh -n agent-report-viewer/pane.sh`
Expected: `ok`（構文エラーなし）

- [ ] **Step 4: コミット**

```bash
git add agent-report-viewer/pane.sh agent-report-viewer/herdr-plugin.toml
git commit -m "agent-report-viewer: add pane entrypoint and manifest"
```

---

### Task 5: 実機 E2E と done 重複の確認

**Files:**
- Modify: （E2E の結果次第。重複発火が確認されたら `on-agent-done.sh` に抑止を追加）

**Interfaces:**
- Consumes: これまでの全成果物、実行中の herdr セッション、`debug.evtdump` が収集した `~/.local/state/herdr/plugins/debug.evtdump/events.log`。

- [ ] **Step 1: done イベントの実データを確認する**

Run: `grep '"agent_status":"done"' ~/.local/state/herdr/plugins/debug.evtdump/events.log`
確認事項: 同一ラン（同じ pane_id の連続した working→done）で `done` が2回以上出ていないか。**2回以上出ていた場合**のみ、`on-agent-done.sh` の `[ "$(field agent_status)" = "done" ] || exit 0` の直後に以下の抑止を入れ、テスト `test_duplicate_done_is_ignored`（同じイベントで `run_hook` を2回呼び、2回目は `plugin pane open` も `mado -remote` も呼ばれないことを assert）を追加する：

```sh
# 同じペインの連続 done を1回に抑止する（60秒窓）。
state_early=${HERDR_PLUGIN_STATE_DIR:-}
if [ -n "$state_early" ]; then
	mkdir -p "$state_early"
	marker="$state_early/last-done-$(printf '%s' "$pane_id" | tr ':' '_')"
	now=$(date +%s)
	last=$(cat "$marker" 2>/dev/null || printf 0)
	if [ $((now - last)) -lt 60 ]; then
		exit 0
	fi
	printf '%s' "$now" > "$marker"
fi
```

（注意: このブロックは `pane_id` を読んだ後に置く必要があるため、実際には Task 2 で入れた `pane_id=$(field pane_id)` 〜 `[ -n "$workspace_id" ] || exit 0` の直後に挿入する。）

- [ ] **Step 2: プラグインを link して実機で動かす**

```bash
herdr plugin link "$(pwd)/agent-report-viewer"
herdr plugin list | grep agent-report-viewer
```

実 agent ラン（このワークスペースの Claude に markdown を書かせる等）を1回完了させ、確認する：
- done 後に「mado report」ペインが split で出現し、生成された md がタブで開く
- もう一度ランさせると、新しいペインではなく**同じペイン**にタブが増える（`herdr plugin log list --plugin mado.agent-report-viewer` で `mado -remote open` 経路に入ったことを確認）
- md を生成しないランでは何も起きない

- [ ] **Step 3: デバッグプラグインを片付ける**

```bash
herdr plugin unlink debug.evtdump
```

- [ ] **Step 4: コミット（変更があれば）**

```bash
git add -A agent-report-viewer
git commit -m "agent-report-viewer: dedupe duplicate done events" # 抑止を入れた場合のみ
```

---

### Task 6: README とリリース準備

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: 完成したプラグイン。README の既存構成（Plugins 表、docs-peek セクション、Planned セクション）。

- [ ] **Step 1: README を更新する**

- Plugins 表に行を追加：`| [`agent-report-viewer`](agent-report-viewer) | `herdr plugin install hidekingerz/herdr-plugin-mado/agent-report-viewer` | Opens the markdown an agent run produced, in mado, when the run is done. |`
- docs-peek セクションと同じ体裁で `## agent-report-viewer` セクションを追加：動作（done → git 差分の md → ワークスペースごとに1枚の mado ペイン、最大4ファイル・新しい順）、Install、Requirements（herdr 0.8.0+ / **mado v1.2.0+**（`-remote` が必要）/ git リポジトリ内でのみ動作）、`herdr plugin log list --plugin mado.agent-report-viewer` によるデバッグ。
- Planned セクションから **agent-report-viewer** の行を削除し、残り2項目を維持する。

- [ ] **Step 2: 表示確認**

Run: `herdr plugin action invoke mado.docs-peek.peek`（mado で README.md を開いて目視確認）

- [ ] **Step 3: コミット**

```bash
git add README.md
git commit -m "README: document agent-report-viewer"
```

push とリリースタグ（v0.2.0 など）はユーザー確認のうえ実施する。
