#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CLAUDE_CONFIG_DIR を尊重する（hooks/claude-agents-strip-model.sh と同じ既定）。
# 無視すると、この環境変数を設定しているユーザーでは agents / skills / bin /
# hooks も settings.json への書き込みも Claude Code が読まない場所に入り、
# エラーも警告も出ないまま「導入したのに一度も動かない」状態になる。
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
AGENTS_DIR="${CLAUDE_DIR}/agents"
SETTINGS="${CLAUDE_DIR}/settings.json"
STAMP="$(date +%Y%m%d%H%M%S)"

mkdir -p "$AGENTS_DIR"

# 1. エージェント定義を symlink（既存の実ファイルは .bak 退避）
for f in "$REPO_DIR"/agents/*.md; do
  name="$(basename "$f")"
  dest="${AGENTS_DIR}/${name}"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "${dest}.bak.${STAMP}"
    echo "backup: ${name} -> ${name}.bak.${STAMP}"
  fi
  ln -sf "$f" "$dest"
  echo "linked: ${name}"
done

# 2. スキル定義を symlink（既存の実ディレクトリは .bak 退避）
SKILLS_DIR="${CLAUDE_DIR}/skills"
mkdir -p "$SKILLS_DIR"
for d in "$REPO_DIR"/skills/*/; do
  [ -d "$d" ] || continue
  src="${d%/}"
  name="$(basename "$src")"
  dest="${SKILLS_DIR}/${name}"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "${dest}.bak.${STAMP}"
    echo "backup: skills/${name} -> ${name}.bak.${STAMP}"
  fi
  ln -sfn "$src" "$dest"
  echo "linked skill: ${name}"
done

# 3. 実行スクリプトを symlink（系列外レビューの起動口。既存の実ファイルは .bak 退避）
BIN_DIR="${CLAUDE_DIR}/bin"
mkdir -p "$BIN_DIR"
for f in "$REPO_DIR"/bin/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  dest="${BIN_DIR}/${name}"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "${dest}.bak.${STAMP}"
    echo "backup: bin/${name} -> ${name}.bak.${STAMP}"
  fi
  chmod +x "$f"
  ln -sf "$f" "$dest"
  echo "linked bin: ${name}"
done

# 4. フックスクリプトを symlink（既存の実ファイルは .bak 退避）
HOOKS_DIR="${CLAUDE_DIR}/hooks"
mkdir -p "$HOOKS_DIR"
for f in "$REPO_DIR"/hooks/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  dest="${HOOKS_DIR}/${name}"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "${dest}.bak.${STAMP}"
    echo "backup: hooks/${name} -> ${name}.bak.${STAMP}"
  fi
  chmod +x "$f"
  ln -sf "$f" "$dest"
  echo "linked hook: ${name}"
done

# settings.json は dotfiles 管理などで symlink になっているケースがある。
# mv はリンクを辿らずリンク自体を置き換えてしまう（dotfiles 側の symlink が
# 黙って切れる）ため、以降のステップは実体パスに対して行う。readlink -f は
# macOS 標準では使えないため、hooks/claude-agents-strip-model.sh と同じ
# 方式（plain な readlink でチェーンを手繰り、最後に `cd && pwd -P` で
# 物理パスへ正規化）で解決する。解決できない場合（壊れた symlink 等）は
# 警告した上でこのステップ全体をスキップする（対話的スクリプトなので
# フックのように無言で降りない）。
#
# この解決ロジックはフック本体と README のアンインストール手順にも同じ形で
# 書かれている（3 箇所の重複）。共通スクリプトへ切り出さない理由は
# hooks/claude-agents-strip-model.sh のコメントを参照（フックは symlink 経由で
# 実行されるため、共通スクリプトを source するには自分自身の symlink 解決が
# 必要になり、新しい壊れ方が増える）。3 箇所を触るときは 3 箇所とも直すこと。
resolve_symlink_chain() {
  local target="$1" link dir resolve_count=0
  while [ -L "$target" ]; do
    resolve_count=$((resolve_count + 1))
    if [ "$resolve_count" -gt 20 ]; then
      return 1
    fi
    link="$(readlink "$target" 2>/dev/null)" || return 1
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname "$target")/${link}" ;;
    esac
  done
  dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$target")"
}

# 元ファイルのパーミッションを新しい settings.json へ引き継ぐ（mktemp は
# 0600 で作るため、引き継がないと mv のたびに 0644 -> 0600 のラチェットが
# 起きる）。hooks/claude-agents-strip-model.sh と同じ方式（GNU coreutils の
# `-f` は `--file-system` と解釈されるため GNU の `stat -c` を先に試し、
# BSD の `stat -f` へフォールバックする）で解決する。
preserve_mode() {
  local src="$1" dst="$2" mode
  mode="$(stat -c '%a' "$src" 2>/dev/null || stat -f '%Lp' "$src" 2>/dev/null)"
  case "$mode" in
    ''|*[!0-9]*) return 0 ;;
  esac
  chmod "$mode" "$dst" 2>/dev/null
}

# mktemp は set -euo pipefail 下では失敗時にスクリプト全体を道連れにして
# 落ちる（読み取り専用の設定ディレクトリ等で実機再現）。settings.json の
# 更新ステップはそれぞれ独立して継続できるべきで、1 ステップの失敗で以降の
# alias 登録等に到達できなくなるのは避けたいので、失敗したら空文字列を
# 返して呼び出し側に警告させ、そのステップだけスキップする（黙って中断
# しない）。
mktemp_settings() {
  mktemp "${1}/.settings.json.install.XXXXXX" 2>/dev/null || printf ''
}

# バックアップは常に元の（symlink 解決前の）パスに置く。$SETTINGS を実体
# パスへ再代入した後だと、settings.json を dotfiles リポジトリで symlink
# 管理しているユーザーのバックアップが dotfiles 実体ディレクトリ側に
# untracked で増え続けてしまう（settings.json は秘密を含みうる）。
SETTINGS_BACKUP="${CLAUDE_DIR}/settings.json.bak.${STAMP}"

SETTINGS_DIR=""
if resolved_settings="$(resolve_symlink_chain "$SETTINGS")"; then
  SETTINGS="$resolved_settings"
  SETTINGS_DIR="$(dirname "$SETTINGS")"
else
  echo "⚠ ${SETTINGS} の実体パスを解決できませんでした（壊れた symlink 等）。settings.json の自動更新をスキップします。"
fi

# 5. settings.json に "agent": "auto-router" を設定 ＋ Stop フックを冪等に登録
if [ -n "$SETTINGS_DIR" ] && command -v jq >/dev/null 2>&1; then
  # cp によるバックアップも mktemp_settings と同じ理由（読み取り専用の
  # 設定ディレクトリ等での実機再現）で失敗しうる。mktemp_settings の
  # フォールバックは各ステップを個別にスキップするだけだが、cp は
  # set -euo pipefail 下でガードせずに落ちるとスクリプト全体を道連れに
  # し、symlink は張られたが settings.json は一切更新されずエイリアス
  # 登録にも到達しないという部分適用で終わる。ここで失敗を捕捉し、
  # settings.json 関連の 3 ステップ（agent / effortLevel / Stop フック
  # 登録）をまとめてスキップして、以降のステップ（エイリアス登録・codex
  # 検出）へ進めるようにする。
  settings_writable=1
  if [ -f "$SETTINGS" ]; then
    if ! cp "$SETTINGS" "$SETTINGS_BACKUP" 2>/dev/null; then
      settings_writable=0
      echo '⚠ settings.json のバックアップ作成に失敗しました（読み取り専用ディレクトリ等）。'
      echo '  "agent" / "effortLevel" / Stop フック登録をまとめてスキップします。手動で'
      echo '  "agent": "auto-router" と "effortLevel": "xhigh" を追加し、Stop フックも手動登録して'
      echo '  ください（claude-agents-strip-model.sh を参照）。'
    fi
  fi

  # Stop フック登録の成否をここで記録する。settings.json の "model" 残留を
  # 検知した際の案内文を、実際にフックが登録できたかどうかで出し分ける
  # ため（登録できていないのに「次のターンで自動的に剥がす」と案内すると
  # 誤誘導になる）。
  hook_registered=0

  if [ "$settings_writable" -eq 1 ]; then
    if [ -f "$SETTINGS" ]; then
      # 一時ファイルは settings.json の実体と同じディレクトリに作る（別デバイス
      # だと mv のアトミック性が失われるため）
      tmp="$(mktemp_settings "$SETTINGS_DIR")"
      if [ -z "$tmp" ]; then
        echo '⚠ 一時ファイルの作成に失敗しました（読み取り専用ディレクトリ等）。"agent" の設定をスキップします。手動で追加してください。'
      elif jq '.agent = "auto-router"' "$SETTINGS" > "$tmp"; then
        preserve_mode "$SETTINGS" "$tmp"
        mv "$tmp" "$SETTINGS"
        echo 'settings.json: "agent": "auto-router" を設定'
      else
        rm -f "$tmp"
        echo '⚠ settings.json への "agent" 設定に失敗しました（jq エラー）。手動で追加してください。'
      fi
    else
      printf '{\n  "agent": "auto-router"\n}\n' > "$SETTINGS"
      echo 'settings.json: "agent": "auto-router" を設定'
    fi

    # effortLevel を "xhigh" に設定する。frontmatter の effort はメイン
    # セッション（auto-router / orchestrator）では発火せず、settings.json の
    # effortLevel が実効値を決める唯一の手段なので（claude-agents-strip-model.sh
    # のヘッダコメントを参照）、ここで能動的に初期値を設定する。以後は
    # Stop フック（claude-agents-strip-model.sh）が毎ターン "xhigh" へ正規化
    # し直すため、`/effort` で書き込まれても恒久化しない。
    # 既に値があり "xhigh" と異なる場合は上書きし、元の値を明示する。
    # 注意: settings.json はグローバル（~/.claude/settings.json）な設定ファイル
    # なので、この effortLevel はマシン全体に効く。このリポジトリと無関係な
    # プロジェクトのメインセッションにも影響する（README の "model" に関する
    # 注意書きと同じ設計上の理由）。
    # 注意: settings.json の effortLevel が受け付ける値は enum で
    # "low"/"medium"/"high"/"xhigh" に限定されており "max" は存在しない
    # （不正値は黙って捨てられる）。orchestrator を "max" で走らせるには
    # settings.json ではなく --effort フラグが必須なのはこのため（cco
    # エイリアス側で --effort max を明示している。後段「6. ペイン起動
    # エイリアス」を参照）。
    prev_effort="$(jq -r 'if has("effortLevel") then (.effortLevel|tojson) else empty end' "$SETTINGS" 2>/dev/null || true)"
    tmp="$(mktemp_settings "$SETTINGS_DIR")"
    if [ -z "$tmp" ]; then
      echo '⚠ 一時ファイルの作成に失敗しました（読み取り専用ディレクトリ等）。"effortLevel" の設定をスキップします。手動で追加してください。'
    elif jq '.effortLevel = "xhigh"' "$SETTINGS" > "$tmp"; then
      preserve_mode "$SETTINGS" "$tmp"
      mv "$tmp" "$SETTINGS"
      if [ -n "$prev_effort" ] && [ "$prev_effort" != '"xhigh"' ]; then
        echo "settings.json: \"effortLevel\": \"xhigh\" を設定（元の値 ${prev_effort} を上書き）"
      else
        echo 'settings.json: "effortLevel": "xhigh" を設定'
      fi
    else
      rm -f "$tmp"
      echo '⚠ settings.json への "effortLevel" 設定に失敗しました（jq エラー）。手動で追加してください。'
    fi

    # Stop フックへ claude-agents-strip-model.sh を追記登録する。既存の Stop
    # エントリ（例: notify-stop.sh）や SessionStart フックは絶対に壊さない。
    # コマンド文字列に claude-agents-strip-model.sh を含むかどうかで既存判定
    # する（完全一致だと ~ 表記の手動登録と絶対パス登録が二重になるため）。
    # 登録するコマンド自体は絶対パスで固定する（~ はフック実行シェルに
    # よっては展開されないため）。`objects` で要素の型を絞り、Stop がオブ
    # ジェクト形式だったり hooks 配列に文字列等が混入していても落ちないよう
    # にする。
    #
    # パスはシェルに解釈されるコマンド文字列の中に埋め込まれるので、シェルの
    # メタ文字を含む場合はクォートする。ホームディレクトリに空白を含む環境
    # （/Users/Taro Yamada/...）だと `bash /Users/Taro` になり毎ターン失敗し、
    # しかも settings.json に焼き付くので後から手で直す羽目になる。
    # 空白等を含まない通常のパスはクォートしない ―― そうしておくと、既存
    # 環境（クォート無しで登録済み）が state=current と判定されて無駄な
    # 書き戻しが起きない。
    #
    # クォートはシングルクォート包み + '\'' エスケープで行う。bash の
    # `printf %q` は制御文字や非 ASCII に対して $'\346...' という bash 方言を
    # 返すことがあり、登録したコマンドを POSIX sh（dash 等）が実行する構成だと
    # 毎ターン失敗する（しかも settings.json に焼き付く）。シングルクォート包み
    # なら全 POSIX sh で安全。
    quote_for_shell() {
      # 置換文字列を変数に組み立てる。"${1//\'/\'\\\'\'}" と直接書くと、二重
      # 引用符の中では \' がバックスラッシュ + ' のまま残るため置換結果が
      # 壊れる（実測: /a/b'c → '/a/b\'\\'\'c' となり sh が構文エラー）。
      local sq="'" esc="'\\''"
      case "$1" in
        # 英数字と _ . / - だけならシェルの解釈と一致するのでそのまま
        *[!A-Za-z0-9_./-]*) printf "'%s'\n" "${1//$sq/$esc}" ;;
        *) printf '%s\n' "$1" ;;
      esac
    }
    HOOK_PATH="${HOOKS_DIR}/claude-agents-strip-model.sh"
    HOOK_CMD="bash $(quote_for_shell "$HOOK_PATH")"
    # クォートが必要なパスなのに、過去の install.sh が書いたクォート無しの
    # 文字列がそのまま残っている場合だけ、その 1 エントリを差し替える。
    # 差し替え対象を「過去の install.sh が書いた形と完全一致」に限定するのは、
    # ~ 表記の手動登録やユーザーが手を入れたエントリを書き換えないため。
    LEGACY_HOOK_CMD="bash ${HOOK_PATH}"

    # 既存判定を登録処理から切り離す。既に登録済みでも毎回「登録（冪等）」と
    # 表示していたのを、エイリアス側と同様に出し分けるため。
    # jq が落ちた場合・想定外の値を返した場合は "error" 扱いにして、書き込みを
    # 一切せずに警告する（重複登録を避けるため、判定できないときは書かない）。
    if ! hook_state="$(jq -r --arg needle "claude-agents-strip-model.sh" --arg cmd "$HOOK_CMD" --arg legacy "$LEGACY_HOOK_CMD" '
      [(.hooks?.Stop? | arrays)[] | objects | (.hooks? | arrays)[] | objects | .command? // empty]
      | if any(. == $cmd) then "current"
        elif ($cmd != $legacy) and any(. == $legacy) then "legacy"
        elif any(contains($needle)) then "current"
        else "absent" end
    ' "$SETTINGS" 2>/dev/null)"; then
      hook_state="error"
    fi

    case "$hook_state" in
      current)
        hook_registered=1
        echo 'settings.json: Stop フックは登録済み（スキップ）'
        ;;
      absent|legacy)
        tmp="$(mktemp_settings "$SETTINGS_DIR")"
        if [ -z "$tmp" ]; then
          echo '⚠ 一時ファイルの作成に失敗しました（読み取り専用ディレクトリ等）。Stop フックの登録をスキップします。手動登録が必要です（claude-agents-strip-model.sh を参照）。'
        elif jq --arg cmd "$HOOK_CMD" --arg legacy "$LEGACY_HOOK_CMD" --arg state "$hook_state" '
          .hooks //= {} |
          .hooks.Stop //= [] |
          if $state == "legacy" then
            .hooks.Stop |= map(
              if type == "object" and (.hooks? | type) == "array" then
                .hooks |= map(if type == "object" and .command == $legacy then .command = $cmd else . end)
              else . end
            )
          else
            .hooks.Stop += [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
          end
        ' "$SETTINGS" > "$tmp"; then
          preserve_mode "$SETTINGS" "$tmp"
          mv "$tmp" "$SETTINGS"
          hook_registered=1
          if [ "$hook_state" = "legacy" ]; then
            echo 'settings.json: Stop フックの登録コマンドをクォート付きに修正（パスに空白等が含まれるため、従来の登録は毎ターン失敗していました）'
          else
            echo 'settings.json: Stop フックに claude-agents-strip-model.sh を登録'
          fi
        else
          rm -f "$tmp"
          echo '⚠ Stop フックの登録に失敗しました（jq エラー）。手動登録が必要です（claude-agents-strip-model.sh を参照）。'
        fi
        ;;
      *)
        echo '⚠ Stop フックの登録状態を判定できませんでした（jq エラー等）。重複登録を避けるため settings.json は変更していません。手動で確認してください（claude-agents-strip-model.sh を参照）。'
        ;;
    esac
  fi

  # "model" 残留チェックは settings_writable の成否に関わらず行う（読み取り
  # だけなのでバックアップ失敗時でも安全に実行できる。書き込みが丸ごと
  # スキップされた場合こそ、ユーザーに現状を伝える必要性が高い）。案内文は
  # hook_registered（上で Stop フック登録が実際に成功したか）で出し分ける。
  # 登録できていないのに「次のターンで自動的に剥がす」と案内すると誤誘導
  # になるため。
  if [ -f "$SETTINGS" ] && jq -e 'has("model")' "$SETTINGS" 2>/dev/null | grep -q true; then
    echo '⚠ settings.json に "model" キーが残っています。'
    echo '  これはメインセッションで agents/*.md の frontmatter に勝つため、model の割当が'
    echo '  settings.json（machine-local・配布されない）と frontmatter の 2 箇所に分裂します。'
    echo '  このリポジトリは model の真実の源を frontmatter に一本化する設計です。'
    if [ "$hook_registered" -eq 1 ]; then
      echo '  上で登録した Stop フックが次のターンの応答完了時に自動で剥がすので、通常は放置'
      echo '  して構いません。すぐに消したい場合は:'
    else
      echo '  Stop フックの登録ができていない（上の警告を参照）ため、次のターンでも自動では'
      echo '  剥がれません。手動で消してください:'
    fi
    # 案内するコマンドの中のパスもクォートする（Stop フック登録と同じ理由。
    # ホームに空白がある環境でそのままコピペすると壊れるため）
    echo "    tmp=\$(mktemp \"${SETTINGS_DIR}/.settings.json.XXXXXX\") && jq 'del(.model)' \"${SETTINGS}\" > \"\$tmp\" && mv \"\$tmp\" \"${SETTINGS}\""
  fi
elif [ -z "$SETTINGS_DIR" ]; then
  : # 実体パスを解決できなかった旨は上ですでに警告済み
else
  echo '⚠ jq が見つかりません。settings.json に手動で "agent": "auto-router" と "effortLevel": "xhigh" を'
  echo '  追加してください。また Stop フックも手動登録が必要です（claude-agents-strip-model.sh を参照）。'
fi

# 6. ペイン起動エイリアス
case "${SHELL##*/}" in
  zsh) RC="${HOME}/.zshrc" ;;
  *)   RC="${HOME}/.bashrc" ;;
esac
MARKER="# >>> claude-agents aliases >>>"
MARKER_END="# <<< claude-agents aliases <<<"
if ! grep -qF "$MARKER" "$RC" 2>/dev/null; then
  cat >> "$RC" << EOF

$MARKER
alias cco='claude --agent orchestrator --effort max'                 # Orchestrator ペイン（管理専任。--effort が settings.json の effortLevel に勝つ）
alias ccd='claude --model fable --agent claude --effort high'        # Decision ペイン（素の Fable で意思決定）
alias ccw='claude -w'                                                # Worker ペイン（worktree 自動作成）
$MARKER_END
EOF
  echo "aliases: ${RC} に追加しました（source ${RC} で有効化）"
else
  echo "aliases: 設定済み（スキップ）"
  # 既存ブロックがある場合、install.sh は MARKER の有無だけで判定して冪等に
  # している（rc は書き換えない）ため、cco が --effort max を含まない古い
  # ブロックのままだと再実行しても更新されない。--effort フラグは
  # settings.json の effortLevel に勝つ唯一の手段なので、放置すると
  # orchestrator の意図した effort（max）が実効しない。ユーザーの rc を
  # 無断で書き換えるのは避け、警告と手動更新の案内に留める。
  # 判定は rc ファイル全体から最後に現れる `alias cco=` 定義を採る。シェル
  # は同名 alias の最後の定義が有効になる（後勝ち）ため、マーカーブロック
  # より後ろにユーザー独自の `alias cco=` があるとそちらが実効する。
  # マーカーブロック内だけを走査すると、ブロックより後ろの定義（実際に
  # 有効な方）を無視してブロック内の（実効していない）定義を見てしまう
  # 偽陽性が実機で再現している。逆にブロック外に古い定義がある場合を
  # 拾えない偽陰性も同様に実機で再現している。
  # ブロック内・ブロック外のどちらにも `alias cco=` が 1 つも無い場合も
  # 「古い」として扱う（下の case のデフォルト分岐が拾う）。
  cco_line="$(grep -F 'alias cco=' "$RC" 2>/dev/null | tail -n1 || true)"
  case "$cco_line" in
    *'--effort max'*) : ;;
    *)
      echo "⚠ ${RC} の cco エイリアスに --effort max がありません（古いブロックのままです）。"
      echo '  --effort フラグは settings.json の effortLevel に勝つため、このままだと orchestrator の'
      echo '  effort が意図どおり max になりません。rc の自動書き換えはしないので、下記のブロックで'
      echo "  ${MARKER} 〜 ${MARKER_END} を手動で置き換えてください:"
      echo ''
      echo "  $MARKER"
      echo "  alias cco='claude --agent orchestrator --effort max'                 # Orchestrator ペイン（管理専任。--effort が settings.json の effortLevel に勝つ）"
      echo "  alias ccd='claude --model fable --agent claude --effort high'        # Decision ペイン（素の Fable で意思決定）"
      echo "  alias ccw='claude -w'                                                # Worker ペイン（worktree 自動作成）"
      echo "  $MARKER_END"
      ;;
  esac
fi

# 7. 系列外レビュー（任意）の前提を検出。未導入でも中断しない
if command -v codex >/dev/null 2>&1; then
  echo "codex: 検出しました（系列外レビューが有効になります）"
else
  echo 'ℹ codex CLI が見つかりません。系列外レビューはスキップされます（構成は壊れません）。'
  echo '  導入すると、独立レビューが走る場面で系列外の第 2 レビュアが並行で走ります。'
fi

# 8. CLAUDE_CONFIG_DIR を使っている環境で、~/.claude 側に残っている旧インストール
#    を検出して知らせる。削除も削除の提案もしない（rc を無断で書き換えない先例に
#    合わせる。旧側の settings.json にはユーザーが導入前から置いていた値が混ざり
#    うるので、こちらの判断で消してよいものではない）。
#    それでも黙ってはいけないのは、旧インストールが「Claude Code が読まないので
#    無害」なのは CLAUDE_CONFIG_DIR が設定されている間だけで、後で外すと黙って
#    復活するため。それを伝えられるのはこのタイミングしかない。
LEGACY_DIR="${HOME}/.claude"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$LEGACY_DIR" != "$CLAUDE_DIR" ] && [ -d "$LEGACY_DIR" ]; then
  legacy_links=0
  legacy_hook=0
  for sub in agents skills bin hooks; do
    for f in "${LEGACY_DIR}/${sub}"/*; do
      # マッチしない場合はパターン文字列そのものが来るので -L で弾かれる
      [ -L "$f" ] || continue
      link_target="$(readlink "$f" 2>/dev/null || true)"
      case "$link_target" in
        "${REPO_DIR}"/*) legacy_links=$((legacy_links + 1)) ;;
      esac
    done
  done
  if [ -f "${LEGACY_DIR}/settings.json" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '[.hooks?.Stop? | arrays | .[] | objects | (.hooks? | arrays)[] | objects | .command? // empty]
              | any(contains("claude-agents-strip-model.sh"))' \
         "${LEGACY_DIR}/settings.json" >/dev/null 2>&1; then
      legacy_hook=1
    fi
  fi
  if [ "$legacy_links" -gt 0 ] || [ "$legacy_hook" -eq 1 ]; then
    echo ''
    echo "⚠ CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} を使っていますが、${LEGACY_DIR} 側にこのリポジトリの"
    echo '  旧インストールが残っています:'
    # set -e 下では `[ ... ] && echo` を単独文に置けない（テストが偽だと
    # スクリプトごと落ちる）ので if で書く
    if [ "$legacy_links" -gt 0 ]; then
      echo "    - agents / skills / bin / hooks の symlink ${legacy_links} 本"
    fi
    if [ "$legacy_hook" -eq 1 ]; then
      echo "    - settings.json の Stop フック登録（claude-agents-strip-model.sh）"
    fi
    echo '  Claude Code は CLAUDE_CONFIG_DIR 側しか読まないので、今は無害です。ただし後で'
    echo '  CLAUDE_CONFIG_DIR の設定を外すと、この旧インストールが黙って復活します（古い agents 定義や'
    echo '  古いパスの Stop フックが効き始めます）。'
    echo '  こちらからは削除しません（旧側の settings.json には導入前からの設定が混ざりうるため）。'
    echo '  不要なら README の「アンインストール」を CLAUDE_CONFIG_DIR を外した状態で実行してください。'
  fi
fi

echo ""
echo "インストール完了。agents は symlink なので、更新はこのリポジトリで git pull するだけです。"
