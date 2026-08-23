# agent-report-viewer — 設計

2026-08-23。この仕様を書く前に、会話上で設計の承認を得ている。

## 目的

agent のランが終わったとき、そのランが生成した markdown を表示する —
ユーザーがランの終了に気づき、ファイルを探し、開く、という手間を無くす。
このプラグインは herdr の agent ステータスイベントを購読し、生成された
markdown を [mado](https://github.com/hidekingerz/mado) で開く。mado の
ペインはワークスペースごとに1枚を再利用する。

このリポジトリで計画している3プラグインの最初の1つ。残りの2つ
（markdown link handler、loop-state dashboard）はこの仕様の対象外。

## 制約

- herdr 0.8.0 以上、mado v1.2.0 以上（`-remote`、`-watch`）が `PATH` にあること。
- docs-peek と同じ構成：POSIX シェルスクリプトと `herdr-plugin.toml` からなる
  プラグインディレクトリ。ビルド工程もデーモンも無し。Linux と macOS。
- フックは agent のステータスが変わるたびに走る。ユーザーの邪魔を
  絶対にしないこと：あらゆる失敗は「何もしない」に静かに倒す。

## 構成

新しいディレクトリ `agent-report-viewer/`、プラグイン id は
`mado.agent-report-viewer`：

| ファイル | 役割 |
| -------- | ---- |
| `herdr-plugin.toml` | マニフェスト：イベント購読とペインのエントリポイント |
| `on-agent-done.sh` | イベントフック：生成された markdown を検出しペインへ渡す |
| `pane.sh` | ペインのエントリポイント：検出したファイルで mado を起動 |

## イベント購読

```toml
[[events]]
on = "pane.agent_status_changed"
command = ["sh", "-c", "exec sh \"$HERDR_PLUGIN_ROOT/on-agent-done.sh\""]
```

マニフェストのイベント名はドット区切り（`pane.agent_status_changed`）。API
イベント型名（`pane_agent_status_changed`）とは異なることに注意（実機
検証済み）。

- イベントコマンドは `HERDR_PLUGIN_EVENT` / `HERDR_PLUGIN_EVENT_JSON` を
  受け取る。ペイロードには `pane_id`、`workspace_id`、`agent_status`
  （`idle | working | blocked | done | unknown`）が入る。
- フックは `agent_status` が `done` でなければ即終了する。
- エントリポイントはすべて `$HERDR_PLUGIN_ROOT` 経由で参照する。herdr は
  プラグインのコマンドをプラグインルートではなくペイン（やイベント）の
  cwd で実行するため — docs-peek 0.1.0 で学んだ教訓。

## 生成された markdown の検出

git 差分ベース。mtime 追跡ではなくこちらを選んだのは、実装が単純で、
「ランの成果物とは、書かれたがまだコミットされていないもの」という
直感に合うため：

1. `herdr pane get <pane_id>`（`HERDR_BIN_PATH`）で agent ペインの cwd を
   解決する。
2. cwd が git のワークツリー内でなければ：静かに終了。
3. `git -C <cwd> status --porcelain` → 変更・未追跡のパスのうち `.md` で
   終わるものを残す。
4. mtime の新しい順に並べ、上限4件。
5. 候補が0件なら：静かに終了。

上限は、markdown を大量に触るランへの保険。最も新しいファイルが
レポートである可能性が高い。

## レポートの表示（ワークスペースごとに1ペイン）

- プラグインは mado のペインをワークスペースごとに1枚だけ保つ。ペインを
  開いたとき、そのワークスペースのペイン id を `HERDR_PLUGIN_STATE_DIR` に
  記録する。
- 記録されたペインがまだ存在すれば（`herdr pane get` で確認。消えていた
  記録は破棄）：`mado -remote open <files…>` で動いている mado にファイルを
  渡す。
- 存在しなければ：`herdr plugin pane open --entrypoint report --placement
  split --direction right --cwd <cwd>` を、ファイルリストを
  `--env MADO_REPORT_FILES=<改行区切りのパス>` に載せて実行する。
  `pane.sh` は `mado -watch <files…>` を起動する（cwd はペインの `--cwd` で
  渡るため引数には含めない。ファイルはタブで開き、`-watch` が内容を
  追従させる）。

## エラー処理

あらゆる失敗 — git が無い、mado が無い、ペインが消えた、ペイロードが
パースできない — は「何もしない」を意味し、exit 0 で終わる。せいぜい
プラグインログ（`herdr plugin log list`）に1行残す程度。フックが
セッション中のユーザーにエラーを見せることは決してあってはならない。

## 実装時に最初に検証すべきリスク

1. **`mado -remote` の宛先解決** — mado のインスタンスが複数動いている
   状態（docs-peek のペインなど）で、`-remote open` がどのインスタンスに
   届くか、正しいインスタンスをどう指定できるかを確認する。インスタンスを
   指定できない場合は、プラグイン自身のペインを閉じて開き直す方式に
   フォールバックする。
2. **`done` の重複抑止** — 1回のランで `pane_agent_status_changed(done)` が
   複数回発火しうるかを確認する。しうるなら、`HERDR_PLUGIN_STATE_DIR` の
   ペイン単位マーカーで重複を抑止する。

## テスト

- シェルスクリプトは単体で実行してテストできる：`HERDR_PLUGIN_EVENT_JSON`
  をモックし、使い捨ての git リポジトリを用意して `on-agent-done.sh` を
  起動し、実行されるはずの herdr / mado コマンドを検証する
  （`HERDR_BIN_PATH` をスタブに向ける）。
- E2E は実際の herdr セッションで手動確認：markdown を書く agent ランを
  実行 → done でペインが出現する。もう一度実行 → 2枚目のペインではなく
  同じペインにタブが増える。markdown に変更が無いランを実行 → 何も
  起きない。

## 対象外

- git 管理外のディレクトリ（mtime フォールバック）— 実際に困ったら再検討。
- ワークスペース横断の集約、過去レポートの履歴、通知。
- Windows。
