#!/bin/sh
# Event hook: agent のランが done になったら、そのランが触った markdown を
# mado のペインで開く。失敗はすべて「何もしない」に倒す。
#
# 「そのランが触った」の判定には開始時刻が要るので、done 以外のステータス
# 変化も見る: working / blocked でランの開始時刻をペインごとに記録し、done で
# それ以降に更新された md だけを対象にする。
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

status=$(field agent_status)
pane_id=$(field pane_id)
[ -n "$pane_id" ] || exit 0

# ペインごとの記録: run-<pane> = 進行中のランの開始時刻、done-<pane> = 直近の
# done の時刻。どちらも epoch 秒を1行。
state=${HERDR_PLUGIN_STATE_DIR:-}
key=$(printf '%s' "$pane_id" | tr -c 'A-Za-z0-9_.-' '_')
run_mark="$state/run-$key"
done_mark="$state/done-$key"

case "$status" in
working|blocked)
	# 承認待ち (blocked) からの再開でも working が来るので、記録が無いときだけ
	# 書く。上書きすると承認待ちより前に書いた md が対象から落ちる。
	if [ -n "$state" ] && [ ! -f "$run_mark" ]; then
		mkdir -p "$state" 2>/dev/null || exit 0
		date +%s > "$run_mark" 2>/dev/null || true
	fi
	exit 0
	;;
done) ;;
*) exit 0 ;;
esac

# このランの基準時刻。開始を見ていれば開始時刻、見ていなければ（ランの途中で
# プラグインが入った等）直近の done の時刻。どちらも無ければ空 = 絞り込まない。
since=""
if [ -n "$state" ]; then
	if [ -f "$run_mark" ]; then
		since=$(cat "$run_mark" 2>/dev/null) || since=""
	elif [ -f "$done_mark" ]; then
		since=$(cat "$done_mark" 2>/dev/null) || since=""
	fi
	# 以降のどこで抜けても次のランが新しい基準で始まるよう、先に更新しておく。
	rm -f "$run_mark" 2>/dev/null || true
	if mkdir -p "$state" 2>/dev/null; then
		date +%s > "$done_mark" 2>/dev/null || true
	fi
fi
case "$since" in *[!0-9]*) since="" ;; esac

# mado が無い環境ではイベント駆動でエラーペインを出さない — 静かに何もしない。
command -v mado >/dev/null 2>&1 || exit 0

workspace_id=$(field workspace_id)
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

# 候補 = 未コミットの markdown（変更・未追跡・ステージ済み）と、基準時刻以降の
# コミットに含まれる markdown。パスはリポジトリのルート基準で返るので、ペインが
# サブディレクトリに居ても $top から解決する。
# --show-toplevel はシンボリックリンクを解決した実体パスを返し、show.sh が渡す
# $PWD 基準のパスと食い違う（同じファイルが別タブになる）。cwd からの相対で
# 求めて、ペインが見ているとおりのパスを保つ。
cdup=$(git -C "$cwd" rev-parse --show-cdup 2>/dev/null) || exit 0
top=$(cd "$cwd/$cdup" 2>/dev/null && pwd) || exit 0
[ -n "$top" ] || exit 0
g() { git -C "$top" -c core.quotePath=false "$@" 2>/dev/null || true; }
changed=$(
	g ls-files --modified --others --exclude-standard -- '*.md'
	g diff --cached --name-only --diff-filter=d -- '*.md'
	if [ -n "$since" ]; then
		g log --since="@$since" --format= --name-only --diff-filter=d -- '*.md'
	fi
)
[ -n "$changed" ] || exit 0

# 基準時刻以降に更新されたものだけ、mtime の新しい順に最大4件、絶対パスで。
# stat は GNU 形式を先に試す — BSD 形式 (-f %m) を GNU stat に渡すと失敗しつつ
# 標準出力にファイルシステム情報を出すので、順序を逆にすると値が壊れる。
files=$(printf '%s\n' "$changed" | sort -u | while IFS= read -r f; do
	[ -n "$f" ] && [ -f "$top/$f" ] || continue
	mtime=$(stat -c %Y "$top/$f" 2>/dev/null || stat -f %m "$top/$f" 2>/dev/null) || continue
	# $( ) の中の case は、古い bash が閉じ括弧を読み違えるので ( を付けて書く。
	case "$mtime" in (''|*[!0-9]*) continue ;; esac
	if [ -n "$since" ] && [ "$mtime" -lt "$since" ]; then continue; fi
	printf '%s\t%s\n' "$mtime" "$top/$f"
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
