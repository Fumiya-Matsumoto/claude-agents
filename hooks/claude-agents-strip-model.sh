#!/usr/bin/env bash
#
# Stop フック: ~/.claude/settings.json から "model" / "effortLevel" キーを剥がす。
#
# 背景（GitHub issue #10）: このリポジトリは model / effort の真実の源を
# agents/*.md の frontmatter に一本化している。しかし settings.json の
# "model" はメインセッションで frontmatter の model に勝つため、`/model`
# コマンド等で settings.json に書き込まれると割当が 2 箇所に分裂し、
# settings.json は machine-local で配布されないので必ずマシン間でズレる。
#
# `/model` はもともと「そのセッション限りの切替」という意味論のコマンドであり、
# それを settings.json への書き込みで恒久設定にしてしまうのが問題の本質。
# このフックは Stop イベント（＝毎ターン）で走り、定着してしまった
# "model" / "effortLevel" を剥がして frontmatter を唯一の真実の源に保つ。
# `/model` は今後もそのセッション限りの切替として機能し続け、恒久化はしない。
#
# 毎ターン走るフックなので、書き込みは必要な場合（キーが実在するとき）に
# 限定する（fast path）。また検証を通らない限り settings.json には一切
# 触れない。セッションの応答完了を壊さないよう、いかなる経路でも非ゼロ
# 終了はしない。
#
# 無効化: 環境変数 CLAUDE_AGENTS_STRIP_MODEL=0 を設定するとこのフックは
# 即座に降りる（このリポジトリと無関係なプロジェクトでも既定モデルを
# 消してしまうことへのオプトアウト手段）。
set -uo pipefail

# HOME が無い環境でも非ゼロ終了しない（set -u 環境下でも安全な参照）
[ -n "${HOME:-}" ] || exit 0

# オプトアウト
[ "${CLAUDE_AGENTS_STRIP_MODEL:-}" = "0" ] && exit 0

# CLAUDE_CONFIG_DIR を尊重する（無視すると書き込み先が読まれない場所になり
# フックが無言で無効化される）
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
SETTINGS="${CLAUDE_DIR}/settings.json"

# jq が無ければ何もできないので即座に降りる
command -v jq >/dev/null 2>&1 || exit 0

# settings.json が無ければ何もしない
[ -f "$SETTINGS" ] || exit 0

# fast path: "model" / "effortLevel" のどちらのキーも無ければ、書き込みを
# 一切せずに終了する。jq 自体の失敗（壊れた JSON 等）も安全側に倒し、
# ここで書き込みをしない。symlink かどうかに関わらず jq は透過的に読める
# ので、この時点では $SETTINGS をそのまま読んで構わない。
has_keys="$(jq 'has("model") or has("effortLevel")' "$SETTINGS" 2>/dev/null)"
jq_status=$?
if [ "$jq_status" -ne 0 ] || [ "$has_keys" != "true" ]; then
  exit 0
fi

# ここから先は書き込みが発生する。$SETTINGS が symlink の場合、mv はリンク
# を辿らずリンク自体を置き換えてしまう（dotfiles 管理の symlink が黙って
# 切れる）ので、実体パスを解決してから実体へ書き込む。readlink -f は
# 移植性が無い環境がある（macOS 標準ではフラグ非対応）ため、plain な
# readlink でチェーンを手繰り、最後に `cd && pwd -P` でディレクトリ部分を
# 物理パスへ正規化する。解決できなければ何もせず終了する。
target="$SETTINGS"
resolve_count=0
while [ -L "$target" ]; do
  resolve_count=$((resolve_count + 1))
  if [ "$resolve_count" -gt 20 ]; then
    # symlink ループ等、異常なチェーン。安全側に倒して何もしない
    exit 0
  fi
  link="$(readlink "$target" 2>/dev/null)" || exit 0
  case "$link" in
    /*) target="$link" ;;
    *)  target="$(dirname "$target")/${link}" ;;
  esac
done
real_dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || exit 0
REAL_SETTINGS="${real_dir}/$(basename "$target")"
[ -f "$REAL_SETTINGS" ] || exit 0

# ロストアップデート対策: 並行セッションが同時に書き込むと、ロック無しでは
# 片方の更新が黙って捨てられる。mkdir はアトミックなのでロックに使う。
# stale lock 対策: プロセスが死んでロックが残ると以後フックが永久に無効化
# されるので、一定時間（60 秒）より古いロックは奪って続行する。
LOCK="${CLAUDE_DIR}/.strip-model.lock"
STALE_SECONDS=60

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    return 0
  fi
  if [ -d "$LOCK" ]; then
    now="$(date +%s 2>/dev/null)" || return 1
    lock_mtime="$(stat -f '%m' "$LOCK" 2>/dev/null || stat -c '%Y' "$LOCK" 2>/dev/null)"
    if [ -n "$lock_mtime" ] && [ $((now - lock_mtime)) -gt "$STALE_SECONDS" ]; then
      rmdir "$LOCK" 2>/dev/null
      mkdir "$LOCK" 2>/dev/null && return 0
    fi
  fi
  return 1
}

# ロック取得に失敗したら即座に諦める（次のターンで再試行されるので
# 取りこぼしの実害は無い）
acquire_lock || exit 0

tmp=""
# SIGTERM 等でフックがタイムアウト・強制終了されても一時ファイルとロックを
# 残さない
trap 'rm -f "$tmp" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 0' TERM INT

# 一時ファイルは実体ファイルと同じディレクトリに作る（mv をアトミックに
# するため）。作成に失敗したら何もせず終了する。
tmp="$(mktemp "${real_dir}/.settings.json.strip-model.XXXXXX" 2>/dev/null)" || exit 0

jq 'del(.model, .effortLevel)' "$REAL_SETTINGS" > "$tmp" 2>/dev/null
jq_del_status=$?

# 元ファイルのパーミッションを一時ファイルへ引き継ぐ（mktemp は 0600 で
# 作るため、引き継がないと mv のたびに 0644 -> 0600 のラチェットが起きる）。
# macOS(BSD) は `stat -f`、Linux(GNU) は `stat -c` なので両対応する。
orig_mode="$(stat -f '%Lp' "$REAL_SETTINGS" 2>/dev/null || stat -c '%a' "$REAL_SETTINGS" 2>/dev/null)"
[ -n "$orig_mode" ] && chmod "$orig_mode" "$tmp" 2>/dev/null

# mv する前に検証する。1 つでも失敗したら mv せず、一時ファイルを消して
# 終了する。
#   - jq の終了ステータスが 0 であること
#   - 一時ファイルが空でないこと
#   - 有効な JSON であること
#   - "agent" キーが残っていること
#     （このリポジトリが導入済みかどうかのスコープガード。del(.model,
#      .effortLevel) は agent キーの有無に関わらず成功するので、この条件
#      が破損検知として働くわけではない。あくまで「auto-router 未設定の
#      環境の settings.json には触れない」という適用範囲の限定。）
if [ "$jq_del_status" -eq 0 ] \
  && [ -s "$tmp" ] \
  && jq -e . "$tmp" >/dev/null 2>&1 \
  && jq -e 'has("agent")' "$tmp" >/dev/null 2>&1; then
  mv "$tmp" "$REAL_SETTINGS"
else
  rm -f "$tmp"
fi

exit 0
