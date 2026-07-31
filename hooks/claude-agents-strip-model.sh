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
#
# ただしトークンの照合だけでは足りない。照合と削除はアトミックではないので、
# 「照合に成功した直後に奪取されて作り直された」ロックを消しうる（check と act
# の間の TOCTOU）。取得・奪取・解放のいずれも、パス名 $LOCK ではなく「自分が
# 触ったそのディレクトリ」を指していることを別の手段で確かめる必要がある。
# 解放側は時間で（release_lock の論証）、奪取側は mtime と inode の組で
# （steal_stale_lock）確かめる。
LOCK="${CLAUDE_DIR}/.strip-model.lock"
LOCK_TOKEN_FILE="${LOCK}/token"
# トークンは <pid>-<epoch>-<乱数>。gc_stale_locks が退避ディレクトリの年齢を
# 名前だけから判断するので、この並び順に依存がある。
LOCK_TOKEN="$$-$(date +%s 2>/dev/null)-${RANDOM:-0}${RANDOM:-0}"
STALE_SECONDS=60
# 解放時に確保しておく余裕（下の release_lock の論証を参照）。
RELEASE_GRACE_SECONDS=5
LOCK_ACQUIRED_AT=""

now_epoch() {
  local now
  now="$(date +%s 2>/dev/null)" || return 1
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$now"
}

# ロックディレクトリの mtime と inode を 1 回の stat で取る。GNU coreutils の
# `stat -f` は `--file-system`（書式指定ではない）と解釈されるため、GNU の
# `-c` を先に試す。BSD の `stat -c` は使い方を stderr に出して終了 1 になる
# だけで stdout を汚さないので、この順序なら両対応が成立する。
lock_stat() {
  local out
  out="$(stat -c '%Y %i' "$1" 2>/dev/null || stat -f '%m %i' "$1" 2>/dev/null)" || return 1
  set -- $out
  [ $# -eq 2 ] || return 1
  case "${1}${2}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s %s\n' "$1" "$2"
}

# 奪取の途中（rename 成功後・rmdir 前）に SIGKILL されると退避ディレクトリが
# 残る。回収経路がどこにも無いと設定ディレクトリ（dotfiles 管理下でありうる）に
# ゴミが溜まり続けるので、書き込み経路に入るたびに古い退避ディレクトリを回収する。
#
# 年齢の判定にディレクトリの mtime を使わないのは、退避ディレクトリが奪われた側の
# 古い mtime をそのまま引き継ぐため（rename は mtime を更新しない）。mtime で
# 判定すると、実行中の奪取 ―― steal_stale_lock が再検証している最中のもの ――
# まで消してしまう。名前に埋め込まれた epoch は奪取者の起動時刻なので、実行中の
# ものは必ず新しく、誤って回収されない。
gc_stale_locks() {
  local now d suffix stamp
  now="$(now_epoch)" || return 0
  for d in "${LOCK}".stale.*; do
    # マッチしない場合はパターン文字列そのものが来るので -d で弾かれる
    [ -d "$d" ] || continue
    suffix="${d##*.stale.}"
    stamp="${suffix#*-}"
    stamp="${stamp%%-*}"
    case "$stamp" in
      ''|*[!0-9]*) continue ;;
    esac
    [ $((now - stamp)) -gt "$STALE_SECONDS" ] || continue
    rm -f "${d}/token" 2>/dev/null
    rmdir "$d" 2>/dev/null
  done
  return 0
}

# mkdir で取り、トークンを書き、読み返して一致を確認する。読み返しまでやるのは
# 「mkdir 直後・トークン書き込み前」に他人がこの空ディレクトリを rmdir して
# しまう窓があるため（その場合トークンの書き込み自体が ENOENT で失敗するので、
# ここで気付いて諦められる）。
try_lock() {
  local started cur
  # 時刻は mkdir より前に読む。$LOCK の mtime は mkdir 以降にしか進まないので
  # started <= mtime($LOCK) が保証され、release_lock の保持時間の見積りが
  # 「実際の年齢以上」に出る側（安全側）へ倒れる。
  started="$(now_epoch)" || return 1
  mkdir "$LOCK" 2>/dev/null || return 1
  LOCK_ACQUIRED_AT="$started"
  # 2>/dev/null を先に置く。リダイレクト自体が失敗したときのエラーは
  # 「その時点までに適用済みの stderr」へ出るので、順序を逆にすると
  # 毎ターン走るフックが stderr を漏らす（実測で確認）
  if printf '%s\n' "$LOCK_TOKEN" 2>/dev/null > "$LOCK_TOKEN_FILE" \
    && [ "$(cat "$LOCK_TOKEN_FILE" 2>/dev/null)" = "$LOCK_TOKEN" ]; then
    return 0
  fi
  # 途中で失敗した。作りかけのディレクトリを残すと、以後 STALE_SECONDS の間
  # 誰もロックを取れなくなる（奪取で自己回復はするが 60 秒無効化される）ので
  # 片付ける。自分が mkdir した直後であり、奪取は 60 秒より古いロックにしか
  # 起きないので、ここで消してよいのは自分のディレクトリだけだと言える。
  # それでも中身が他人のトークンだった場合（想定外）は触らない。
  cur="$(cat "$LOCK_TOKEN_FILE" 2>/dev/null)"
  if [ -z "$cur" ] || [ "$cur" = "$LOCK_TOKEN" ]; then
    rm -f "$LOCK_TOKEN_FILE" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
  fi
  LOCK_ACQUIRED_AT=""
  return 1
}

# stale なロックを rename で奪う。$LOCK を直接 rmdir すると、その隙に他人が
# 取り直した「生きたロック」を消してしまう（上記 (b)）。
#
# rename がアトミックであることが保証するのは「同じディレクトリを奪い合った
# 複数プロセスのうち成功するのは 1 つだけ」までで、「掴んだものが stale だった
# あのディレクトリである」ことは保証しない ―― stat してから mv するまでの間に、
# 元の stale が誰かに回収され、別プロセスが $LOCK に生きたロックを作りうる。
# そこで mv の後に退避先を stat し直し、mtime と inode の組が stat 時点と一致
# することを確認する。退避名は自分のトークン入りで他者が構築しないパスなので、
# この再検証は競合しない。inode 番号は rmdir 後に再利用されうるが、作り直された
# ロックの mtime は必ず現在時刻なので、組で見れば区別できる。
steal_stale_lock() {
  local now before after stale
  # symlink を張られている場合は触らない（退避後の rm がリンク先の token を
  # 消しうるため）
  [ -d "$LOCK" ] && [ ! -L "$LOCK" ] || return 1
  now="$(now_epoch)" || return 1
  before="$(lock_stat "$LOCK")" || return 1
  set -- $before
  [ $((now - $1)) -gt "$STALE_SECONDS" ] || return 1
  stale="${LOCK}.stale.${LOCK_TOKEN}"
  mv "$LOCK" "$stale" 2>/dev/null || return 1
  after="$(lock_stat "$stale")" || return 1
  if [ "$after" != "$before" ]; then
    # 生きたロックを掴んでしまった。中身は壊さずそのまま残し、gc_stale_locks
    # に回収させる（掴まれた側の release_lock は $LOCK にトークンが無いので
    # 何もしない）。ロックは取れていないので呼び出し側は降りる。
    return 1
  fi
  rm -f "${stale}/token" 2>/dev/null
  rmdir "$stale" 2>/dev/null
  return 0
}

acquire_lock() {
  gc_stale_locks
  try_lock && return 0
  steal_stale_lock || return 1
  try_lock
}

# 自分のトークンと一致し、かつ「まだ奪取されうる時刻に達していない」ときだけ
# 解放する。トークン照合だけでは、照合に成功した直後に奪取されて作り直された
# ロックを rm/rmdir で消してしまう（check と act の間の TOCTOU）。
#
# なぜ時間の確認で TOCTOU が閉じるか:
#   - $LOCK が他人に奪われるのは、その他人が now - mtime($LOCK) > STALE_SECONDS
#     を観測したときだけ（steal_stale_lock 以外に $LOCK を消す経路は無い）
#   - mtime($LOCK) は自分が取得した時刻で、取得後こちらは $LOCK を触らない。
#     さらに LOCK_ACQUIRED_AT は mkdir より前に読んだ時刻なので
#     LOCK_ACQUIRED_AT <= mtime($LOCK)。したがって
#     now - LOCK_ACQUIRED_AT >= now - mtime($LOCK) で、こちらの見積りは実際の
#     年齢以上（安全側）になる
#   - 解放の直前に now - LOCK_ACQUIRED_AT <= STALE_SECONDS - RELEASE_GRACE_SECONDS
#     を確認できたなら、この瞬間まで誰も奪取条件を満たしていない。かつ奪取条件が
#     成立するのは最短でも RELEASE_GRACE_SECONDS 秒後なので、続く rm と rmdir の
#     2 システムコールにはそれだけの猶予がある
#   - 超えていた場合は「奪われていないこと」を保証できないので、何もせずに降りる。
#     放置したロックは次に来た誰かが stale として回収するので詰まらない
#   （前提: date +%s が単調に進むこと。時計が飛べば奪取側の判定も同じだけずれる。
#     経過時間が負になった場合も保証が崩れるので何もしない）
release_lock() {
  local now age
  [ -n "$LOCK_ACQUIRED_AT" ] || return 0
  [ "$(cat "$LOCK_TOKEN_FILE" 2>/dev/null)" = "$LOCK_TOKEN" ] || return 0
  now="$(now_epoch)" || return 0
  age=$((now - LOCK_ACQUIRED_AT))
  [ "$age" -ge 0 ] || return 0
  [ "$age" -le $((STALE_SECONDS - RELEASE_GRACE_SECONDS)) ] || return 0
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
