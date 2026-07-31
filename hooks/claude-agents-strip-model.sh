#!/usr/bin/env bash
#
# Stop フック: ~/.claude/settings.json から "model" キーを剥がし、
# "effortLevel" を "xhigh" に正規化する。
#
# 背景（GitHub issue #10）: このリポジトリは model の真実の源を
# agents/*.md の frontmatter に一本化している。settings.json の
# "model" はメインセッションで frontmatter の model に勝つため、`/model`
# コマンド等で settings.json に書き込まれると割当が 2 箇所に分裂し、
# settings.json は machine-local で配布されないので必ずマシン間でズレる。
#
# `/model` はもともと「そのセッション限りの切替」という意味論のコマンドであり、
# それを settings.json への書き込みで恒久設定にしてしまうのが問題の本質。
# このフックは Stop イベント（＝毎ターン）で走り、定着してしまった
# "model" を剥がして frontmatter を唯一の真実の源に保つ。
# `/model` は今後もそのセッション限りの切替として機能し続け、恒久化はしない。
#
# "effortLevel" も同型の問題を抱える（2026-07-31 に方針変更）: effort の
# 優先順位は `--effort` フラグ > settings.json の effortLevel > frontmatter
# の effort であり、かつメインセッション（auto-router / orchestrator）では
# frontmatter の effort がそもそも発火しない。つまり settings.json の
# effortLevel は、メインセッション 2 体の effort を制御できる唯一の手段
# であり、model と違って「剥がせば frontmatter に一本化される」という
# 関係が成立しない。install.sh は effortLevel を "xhigh" に設定するが、
# `/effort` コマンド等でそれが別の値に書き換わると、"model" とまったく
# 同型の問題が起きる ―― 「そのセッション限りのつもりの切替」が
# settings.json への書き込みで恒久化し、machine-local な settings.json は
# 配布されないので必ずマシン間でズレる。このフックは "model" を剥がすのと
# 同じタイミングで effortLevel を "xhigh" へ正規化することで、`/effort`
# を model と同じくセッション限りの切替に戻す。正規化をフック側（symlink
# 配布）に置くのは、install.sh の再実行を待たずに全マシンへ即座に伝播
# させるため。
#
# 毎ターン走るフックなので、書き込みは必要な場合（"model" が実在する、
# または effortLevel が "xhigh" 以外のとき）に限定する（fast path）。また
# 検証を通らない限り settings.json には一切触れない。セッションの応答
# 完了を壊さないよう、いかなる経路でも非ゼロ終了はしない。
#
# 無効化: 環境変数 CLAUDE_AGENTS_STRIP_MODEL=0 を設定するとこのフックは
# 即座に降りる（このリポジトリと無関係なプロジェクトでも既定モデルや
# effortLevel を書き換えてしまうことへのオプトアウト手段）。
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

# fast path: "model" が無く、かつ effortLevel が既に "xhigh" であれば、
# 書き込みを一切せずに終了する。毎ターン走るフックなので無駄な書き込みを
# 増やさない。jq 自体の失敗（壊れた JSON 等）も安全側に倒し、ここで
# 書き込みをしない。symlink かどうかに関わらず jq は透過的に読めるので、
# この時点では $SETTINGS をそのまま読んで構わない。
#
# has("agent") をここにも合流させる理由: 後段（mv 直前）に "agent" キーの
# スコープガードがあり、"agent" が無い settings.json（このリポジトリ未
# 導入の環境）への書き込みは常にそこで却下される。値ベースの判定
# （"model" が無く effortLevel が "xhigh"）は書き込みが実際に起きない限り
# 解消しない。つまり fast path 側にこのガードを入れないと、"agent" が
# 無い環境では毎ターン「ロック取得 → 一時ファイル作成 → jq 実行 → 後段
# ガードで却下 → 削除」という無駄なサイクルが永久に続いてしまう。
needs_write="$(jq '(has("agent")) and ((has("model")) or (.effortLevel != "xhigh"))' "$SETTINGS" 2>/dev/null)"
jq_status=$?
if [ "$jq_status" -ne 0 ] || [ "$needs_write" != "true" ]; then
  exit 0
fi

# ここから先は書き込みが発生する。$SETTINGS が symlink の場合、mv はリンク
# を辿らずリンク自体を置き換えてしまう（dotfiles 管理の symlink が黙って
# 切れる）ので、実体パスを解決してから実体へ書き込む。readlink -f は
# 移植性が無い環境がある（macOS 標準ではフラグ非対応）ため、plain な
# readlink でチェーンを手繰り、最後に `cd && pwd -P` でディレクトリ部分を
# 物理パスへ正規化する。解決できなければ何もせず終了する。
#
# この解決ロジックは install.sh と README のアンインストール手順にも同じ形で
# 書かれている（3 箇所の重複）。共通スクリプトへ切り出さないのは意図的で、
# このフックは ~/.claude/hooks/ へ symlink として配布され「その symlink から」
# 実行されるため、共通スクリプトを source するには自分自身の symlink を解決して
# リポジトリ位置を突き止める必要があり、リポジトリの移動・削除で毎ターン
# stderr を吐く新しい壊れ方を持ち込むから。README 側は対話シェルへコピペする
# ワンライナーで、リポジトリが消えた後に実行されうるので同様に source できない。
# 3 箇所を触るときは 3 箇所とも直すこと（tests/run.sh がフックと install.sh の
# 双方について symlink の絶対 / 相対 / 多段 / ループ / 壊れを検証する）。
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
#
# ロックの所有権はディレクトリ内のトークンファイルで表す。無条件に rmdir する
# 実装だと、(a) 60 秒を超えて走った A の EXIT trap が、奪取した B のロックを
# 解放してしまう、(b) A・B が同時に stale 判定 → A が奪って mkdir 成功 → 直後の
# B の rmdir が A の新しいロックを消す、の 2 つで両者が同時にロックを持つ。
# トークンを置くこと自体が rmdir の防壁にもなる（生きたロックは非空なので
# 他人の rmdir は必ず ENOTEMPTY で失敗する）。
LOCK="${CLAUDE_DIR}/.strip-model.lock"
LOCK_TOKEN_FILE="${LOCK}/token"
LOCK_TOKEN="$$-$(date +%s 2>/dev/null)-${RANDOM:-0}${RANDOM:-0}"
STALE_SECONDS=60

# mkdir で取り、トークンを書き、読み返して一致を確認する。読み返しまでやるのは
# 「mkdir 直後・トークン書き込み前」に他人の release がこの空ディレクトリを
# rmdir してしまう窓があるため（その場合トークンの書き込み自体が ENOENT で
# 失敗するので、ここで気付いて諦められる）。
try_lock() {
  mkdir "$LOCK" 2>/dev/null || return 1
  # 2>/dev/null を先に置く。リダイレクト自体が失敗したときのエラーは
  # 「その時点までに適用済みの stderr」へ出るので、順序を逆にすると
  # 毎ターン走るフックが stderr を漏らす（実測で確認）
  printf '%s\n' "$LOCK_TOKEN" 2>/dev/null > "$LOCK_TOKEN_FILE" || return 1
  [ "$(cat "$LOCK_TOKEN_FILE" 2>/dev/null)" = "$LOCK_TOKEN" ] || return 1
  return 0
}

# stale なロックを rename で奪う。$LOCK を直接 rmdir すると、その隙に他人が
# 取り直した「生きたロック」を消してしまう（上記 (b)）。rename はアトミックで、
# 同時に stale 判定した複数プロセスのうち成功するのは 1 つだけなので、奪取者が
# 一意に決まる。奪った後は退避名の側だけを片付けるので、他人の新しいロックには
# 触れない。
steal_stale_lock() {
  local now lock_mtime stale
  # symlink を張られている場合は触らない（退避後の rm がリンク先の token を
  # 消しうるため）
  [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  # GNU coreutils の `stat -f` は `--file-system`（書式指定ではない）と
  # 解釈されるため、GNU の `-c` を先に試す。BSD の `stat -c` は使い方を
  # stderr に出して終了 1 になるだけで stdout を汚さないので、この順序
  # なら両対応が成立する。
  lock_mtime="$(stat -c '%Y' "$LOCK" 2>/dev/null || stat -f '%m' "$LOCK" 2>/dev/null)"
  case "$lock_mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ $((now - lock_mtime)) -gt "$STALE_SECONDS" ] || return 1
  stale="${LOCK}.stale.${LOCK_TOKEN}"
  mv "$LOCK" "$stale" 2>/dev/null || return 1
  rm -f "${stale}/token" 2>/dev/null
  rmdir "$stale" 2>/dev/null
  return 0
}

acquire_lock() {
  try_lock && return 0
  steal_stale_lock || return 1
  try_lock
}

# 自分のトークンと一致するときだけ解放する（他人のロックを解放しない）。
release_lock() {
  [ "$(cat "$LOCK_TOKEN_FILE" 2>/dev/null)" = "$LOCK_TOKEN" ] || return 0
  rm -f "$LOCK_TOKEN_FILE" 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
  return 0
}

# ロック取得に失敗したら即座に諦める（次のターンで再試行されるので
# 取りこぼしの実害は無い）
acquire_lock || exit 0

tmp=""
# SIGTERM 等でフックがタイムアウト・強制終了されても一時ファイルとロックを
# 残さない
trap 'rm -f "$tmp" 2>/dev/null; release_lock' EXIT
trap 'exit 0' TERM INT

# 一時ファイルは実体ファイルと同じディレクトリに作る（mv をアトミックに
# するため）。作成に失敗したら何もせず終了する。
tmp="$(mktemp "${real_dir}/.settings.json.strip-model.XXXXXX" 2>/dev/null)" || exit 0

# compare-and-swap 用の指紋。上の mkdir ロックは strip-model フック同士しか
# 調停しないので、jq で読み出してから mv するまでの間に Claude Code 本体
# （`/config`・`/model`・`/effort` 等）が settings.json を書くと、その更新が
# "model" 以外の任意のキーごと巻き戻る。読み出し「前」に指紋を取り、mv の
# 直前に取り直して一致する場合だけ置き換える。
#
# 指紋は mtime（秒）・サイズ・inode の 3 つ。1 回の stat で取る。GNU の
# `stat -f` は `--file-system` と解釈されるため GNU の `-c` を先に試す
# （steal_stale_lock と同じ理由）。
#
# 取り逃すケース（この CAS の限界。ゼロにはできない）:
#   - mtime の粒度が 1 秒までの環境（HFS+ 等）で、同一秒内に「サイズも inode も
#     変えない」上書き（同じ長さの in-place 書き換え）が起きた場合。inode を
#     見ているので、一時ファイル + rename で書くプロセス（Claude Code 本体・
#     このフック自身）は同一秒・同一サイズでも検出できる。素の in-place 書き
#     込みだけがこの穴に残る
#   - 最後の stat から rename までの数マイクロ秒。POSIX に「指紋が一致する
#     ときだけ rename する」アトミック操作は無いので、窓は狭められるだけで
#     消えない
#   - symlink チェーン自体の差し替え（実体パスは最初に解決したものを使い、
#     mv 直前に再解決しない）
# いずれも取り逃した場合の被害は従来と同じ（本体の更新が 1 回巻き戻る）で、
# 巻き戻った側は次のターンに再適用されれば復旧する。
fingerprint() {
  local fp v
  fp="$(stat -c '%Y %s %i' "$1" 2>/dev/null || stat -f '%m %z %i' "$1" 2>/dev/null)" || return 1
  set -- $fp
  [ $# -eq 3 ] || return 1
  for v in "$@"; do
    case "$v" in
      ''|*[!0-9]*) return 1 ;;
    esac
  done
  printf '%s\n' "$fp"
}

# 指紋が取れない環境（stat が無い等）では書き込みを諦める。CAS 無しで書くと
# 本体の更新を黙って捨てうるので、安全側（何もしない）に倒す。
fp_before="$(fingerprint "$REAL_SETTINGS")" || fp_before=""
[ -n "$fp_before" ] || exit 0

jq 'del(.model) | .effortLevel = "xhigh"' "$REAL_SETTINGS" 2>/dev/null > "$tmp"
jq_transform_status=$?

# 元ファイルのパーミッションを一時ファイルへ引き継ぐ（mktemp は 0600 で
# 作るため、引き継がないと mv のたびに 0644 -> 0600 のラチェットが起きる）。
# macOS(BSD) は `stat -f`、Linux(GNU) は `stat -c` なので両対応するが、GNU
# の `-f` は `--file-system` と解釈されるため GNU の `-c` を先に試す
# （上の lock_mtime と同じ理由）。
orig_mode="$(stat -c '%a' "$REAL_SETTINGS" 2>/dev/null || stat -f '%Lp' "$REAL_SETTINGS" 2>/dev/null)"
case "$orig_mode" in
  ''|*[!0-9]*) orig_mode="" ;;
esac
[ -n "$orig_mode" ] && chmod "$orig_mode" "$tmp" 2>/dev/null

# mv する前に検証する。1 つでも失敗したら mv せず、一時ファイルを消して
# 終了する。
#   - jq の終了ステータスが 0 であること
#   - 一時ファイルが空でないこと
#   - 有効な JSON であること
#   - "agent" キーが残っていること
#     （このリポジトリが導入済みかどうかのスコープガード。del(.model) |
#      .effortLevel = "xhigh" は agent キーの有無に関わらず成功するので、
#      この条件が破損検知として働くわけではない。あくまで「auto-router
#      未設定の環境の settings.json には触れない」という適用範囲の限定。）
if [ "$jq_transform_status" -eq 0 ] \
  && [ -s "$tmp" ] \
  && jq -e . "$tmp" >/dev/null 2>&1 \
  && jq -e 'has("agent")' "$tmp" >/dev/null 2>&1; then
  # compare-and-swap: 読み出し時点から実体が変わっていたら諦める（本体の
  # 書き込みを巻き戻さない）。諦めても次のターンのフックが再試行するので
  # 実害は無い。
  fp_now="$(fingerprint "$REAL_SETTINGS")" || fp_now=""
  if [ -n "$fp_now" ] && [ "$fp_now" = "$fp_before" ]; then
    # mv の失敗（権限・別デバイス等）は放置すると永久に気付かれないので
    # stderr に 1 行出す。非ゼロ終了はしない（セッションの応答完了を
    # 壊さないため）。一時ファイルは EXIT trap が片付ける。
    if ! mv "$tmp" "$REAL_SETTINGS" 2>/dev/null; then
      printf '%s\n' "claude-agents-strip-model: ${REAL_SETTINGS} の更新に失敗しました（権限・マウント状態を確認してください）" >&2
    fi
  else
    rm -f "$tmp"
  fi
else
  rm -f "$tmp"
fi

exit 0
