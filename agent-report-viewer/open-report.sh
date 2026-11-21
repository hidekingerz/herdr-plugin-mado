#!/bin/sh
# 指定した markdown を、ワークスペースごとに1枚の mado report ペインで開く。
# on-agent-done.sh（イベント駆動）と show.sh（明示呼び出し）の共通部分。
#
# 使い方: open-report.sh <絶対パス…>
# 環境変数:
#   REPORT_WORKSPACE_ID   必須。ペインと socket をこの単位で1つに保つ
#   REPORT_TARGET_PANE    任意。新規ペインをこのペインの右に split する
#   REPORT_CWD            任意。新規ペインの cwd（既定: 先頭ファイルのディレクトリ）
#   HERDR_PLUGIN_STATE_DIR 必須。record と socket の置き場所
#   HERDR_BIN_PATH        任意。herdr CLI（既定: PATH の herdr）
#   XDG_RUNTIME_DIR / TMPDIR 任意。既に動いている mado のソケットを探す場所
# 失敗はすべて「何もしない・exit 0」に倒す。
set -eu

[ $# -gt 0 ] || exit 0
workspace_id=${REPORT_WORKSPACE_ID:-}
[ -n "$workspace_id" ] || exit 0
state=${HERDR_PLUGIN_STATE_DIR:-}
[ -n "$state" ] || exit 0
herdr=${HERDR_BIN_PATH:-herdr}

mkdir -p "$state" 2>/dev/null || exit 0
sock="$state/report-$workspace_id.sock"

# 開いた／タブ追加したファイル名をトーストで知らせる。別ペインを見ている間に
# レポートが出たことに気づけるように。失敗しても無視する（exit 0 方針）。
notify() { # <絶対パス…>
	body=""; n=0
	for f in "$@"; do
		n=$((n + 1))
		[ "$n" -le 3 ] && body="${body}${body:+, }$(basename "$f")"
	done
	[ "$n" -gt 3 ] && body="$body 他$((n - 3))件"
	"$herdr" notification show "mado report" --body "$body" --sound none >/dev/null 2>&1 || true
}
record="$state/pane-$workspace_id"

# 記録された報告ペインがまだ生きていれば、その mado にタブとして渡す。
if [ -f "$record" ] && "$herdr" pane get "$(cat "$record")" >/dev/null 2>&1; then
	if MADO_SOCKET=$sock mado -remote open "$@" >/dev/null 2>&1; then
		notify "$@"
		exit 0
	fi
	# ペインは居るが mado がこの socket で応答しない（herdr 再起動でペインが
	# 復元され env が失われた、など）。生きた孤児を残したまま開き直すと
	# 重複するので、先に閉じてから開き直す。
	"$herdr" pane close "$(cat "$record")" >/dev/null 2>&1 || true
fi
rm -f "$record" 2>/dev/null || true

# report ペインが無いとき: 同じタブで既に mado が動いていれば（ユーザーが手で
# 起動したもの、docs-peek のペイン）、ペインを増やさずそこへタブとして渡す。
# 送り先は推測しない — herdr にそのペインの前面プロセスを聞いて mado の pid を
# 取り、その pid のソケットを直接指定する。

# pid の mado が listen しているソケットのパスを返す。mado の既定の置き場所
# （$XDG_RUNTIME_DIR/mado/<pid>.sock、無ければ一時ディレクトリの
# mado-<uid>/<pid>.sock）と同じ規則。フックとペインで環境変数が食い違っても
# 拾えるよう、ありうる場所を順に見る。MADO_SOCKET 指定で起動した mado
# （loop-dash など）はここに居ないので、自然に対象外になる。
sock_for_pid() { # <pid>
	uid=$(id -u 2>/dev/null) || uid=""
	for d in "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/mado}" \
		"${TMPDIR:+${TMPDIR%/}/mado-$uid}" "/tmp/mado-$uid" "/run/user/$uid/mado"; do
		[ -n "$d" ] || continue
		if [ -e "$d/$1.sock" ]; then
			printf '%s' "$d/$1.sock"
			return 0
		fi
	done
	return 1
}

# 対象ペインと同じタブに居る、他のペインの id を1行ずつ返す。別タブの mado は
# 画面に見えていないので送り先にしない。
panes_in_same_tab() { # <target-pane>
	list=$("$herdr" pane list --workspace "$workspace_id" 2>/dev/null) || return 0
	if command -v jq >/dev/null 2>&1; then
		pairs=$(printf '%s' "$list" | jq -r '.result.panes[]? | "\(.pane_id)\t\(.tab_id)"' 2>/dev/null) || pairs=""
	else
		# 各ペインは pane_id → tab_id の順に1つずつ持つ（herdr は compact JSON を
		# キーのアルファベット順で出す前提）。出現順に組にする。
		pairs=$(printf '%s' "$list" | grep -oE '"(pane_id|tab_id)":"[^"]*"' \
			| awk -F'"' '$2=="pane_id"{p=$4} $2=="tab_id"{print p "\t" $4}') || pairs=""
	fi
	printf '%s\n' "$pairs" | awk -F'\t' -v t="$1" '
		{ id[NR]=$1; tab[NR]=$2; if ($1==t) mine=$2 }
		END { if (mine!="") for (i=1;i<=NR;i++) if (id[i]!=t && tab[i]==mine) print id[i] }'
}

# ペインの前面で動いている mado の pid を1行ずつ返す。
mado_pids_in_pane() { # <pane-id>
	info=$("$herdr" pane process-info --pane "$1" 2>/dev/null) || return 0
	if command -v jq >/dev/null 2>&1; then
		printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[]? | select(.name=="mado") | .pid' 2>/dev/null || true
	else
		printf '%s' "$info" | grep -o '"name":"mado","pid":[0-9]*' | sed 's/.*://' || true
	fi
}

if [ -n "${REPORT_TARGET_PANE:-}" ]; then
	for p in $(panes_in_same_tab "$REPORT_TARGET_PANE"); do
		for pid in $(mado_pids_in_pane "$p"); do
			s=$(sock_for_pid "$pid") || continue
			if MADO_SOCKET=$s mado -remote open "$@" >/dev/null 2>&1; then
				# ユーザーのペインなので record には書かない（閉じる対象にしない）。
				notify "$@"
				exit 0
			fi
		done
	done
fi

# pane.sh へは改行区切りで渡す。
files=""
for f in "$@"; do
	files="${files}${files:+
}$f"
done
cwd=${REPORT_CWD:-$(dirname "$1")}
opened=$files

set -- --plugin mado.agent-report-viewer --entrypoint report
if [ -n "${REPORT_TARGET_PANE:-}" ]; then
	set -- "$@" --target-pane "$REPORT_TARGET_PANE"
fi
out=$("$herdr" plugin pane open "$@" \
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
IFS='
'
set -f
# shellcheck disable=SC2086
set -- $opened
set +f
unset IFS
notify "$@"
exit 0
