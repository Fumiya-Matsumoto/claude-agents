#!/usr/bin/env bash
# install.sh と README のアンインストール手順のケース。
# tests/run.sh から source される（単体では動かない）。

run_install() {
  assert_sandboxed_home
  bash "$INSTALL" >"${SANDBOX}/install.stdout" 2>"${SANDBOX}/install.stderr"
  INSTALL_STATUS=$?
  INSTALL_OUT="$(cat "${SANDBOX}/install.stdout")"
  INSTALL_ERR="$(cat "${SANDBOX}/install.stderr")"
  return 0
}

# settings.json に登録された strip-model の Stop コマンド文字列を全部出す
registered_hook_commands() { # settings_path
  jq -r '[.hooks.Stop[]? | objects | .hooks[]? | objects | .command? // empty]
         | map(select(contains("claude-agents-strip-model.sh"))) | .[]' "$1" 2>/dev/null
}

# ---------------------------------------------------------------- 基本

case_t30_install_fresh() {
  local s="${HOME}/.claude/settings.json"
  run_install
  assert_eq "t30 終了ステータス" "$INSTALL_STATUS" "0"
  [ -L "${HOME}/.claude/agents/auto-router.md" ] || fail "t30: agents の symlink が無い"
  [ -L "${HOME}/.claude/hooks/claude-agents-strip-model.sh" ] || fail "t30: hooks の symlink が無い"
  [ -L "${HOME}/.claude/bin/codex-review" ] || fail "t30: bin の symlink が無い"
  assert_file_exists "t30 settings.json" "$s"
  assert_eq "t30 agent が設定される" "$(jq -r '.agent' "$s")" "auto-router"
  assert_eq "t30 effortLevel が設定される" "$(jq -r '.effortLevel' "$s")" "xhigh"
  assert_eq "t30 Stop フックが 1 件登録される" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
  assert_contains "t30 登録メッセージ" "$INSTALL_OUT" "Stop フックに claude-agents-strip-model.sh を登録"
  assert_contains "t30 エイリアス追加" "$INSTALL_OUT" "aliases:"
  assert_contains "t30 rc にマーカー" "$(cat "${HOME}/.bashrc")" ">>> claude-agents aliases >>>"
}

# 再実行しても重複せず、「登録済み（スキップ）」と出し分ける
case_t31_install_idempotent() {
  local s="${HOME}/.claude/settings.json" first
  run_install
  first="$(cat "$s")"
  run_install
  assert_eq "t31 2 回目の終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t31 Stop フックは 1 件のまま" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
  assert_contains "t31 登録済みは出し分ける" "$INSTALL_OUT" "Stop フックは登録済み（スキップ）"
  assert_not_contains "t31 「登録」とは言わない" "$INSTALL_OUT" "Stop フックに claude-agents-strip-model.sh を登録"
  assert_contains "t31 エイリアスもスキップ表示" "$INSTALL_OUT" "aliases: 設定済み（スキップ）"
  assert_eq "t31 settings.json の内容が同じ" "$(cat "$s")" "$first"
}

# ---------------------------------------------------------------- CLAUDE_CONFIG_DIR

case_t32_install_claude_config_dir() {
  local custom="${SANDBOX}/xdg/claude" s
  s="${custom}/settings.json"
  export CLAUDE_CONFIG_DIR="$custom"
  run_install
  unset CLAUDE_CONFIG_DIR
  assert_eq "t32 終了ステータス" "$INSTALL_STATUS" "0"
  [ -L "${custom}/agents/auto-router.md" ] || fail "t32: agents が CLAUDE_CONFIG_DIR に入らない"
  [ -L "${custom}/skills/agents-feedback" ] || fail "t32: skills が CLAUDE_CONFIG_DIR に入らない"
  [ -L "${custom}/bin/codex-review" ] || fail "t32: bin が CLAUDE_CONFIG_DIR に入らない"
  [ -L "${custom}/hooks/claude-agents-strip-model.sh" ] || fail "t32: hooks が CLAUDE_CONFIG_DIR に入らない"
  assert_eq "t32 settings.json も CLAUDE_CONFIG_DIR 側" "$(jq -r '.agent' "$s")" "auto-router"
  assert_contains "t32 Stop 登録も CLAUDE_CONFIG_DIR 側のパス" "$(registered_hook_commands "$s")" "$custom"
  assert_file_absent "t32 ~/.claude を作らない" "${HOME}/.claude"
}

# ---------------------------------------------------------------- クォート

# ホームディレクトリに空白がある環境で、登録されたコマンド文字列が
# そのままシェルで実行できること（`bash /Users/Taro` にならない）
case_t33_install_quotes_hook_path() {
  local s cmd legacy status
  export HOME="${SANDBOX}/Taro Yamada"
  mkdir -p "$HOME"
  s="${HOME}/.claude/settings.json"
  run_install
  assert_eq "t33 終了ステータス" "$INSTALL_STATUS" "0"
  cmd="$(registered_hook_commands "$s")"
  assert_eq "t33 シングルクォートで包まれている" \
    "$cmd" "bash '${HOME}/.claude/hooks/claude-agents-strip-model.sh'"
  # POSIX sh（bash 方言でないこと）でも解釈できること。printf %q は
  # $'\346...' 形式を返しうるので、シングルクォート包みであることが要る
  /bin/sh -c "$cmd" >/dev/null 2>&1
  assert_eq "t33 POSIX sh でも実行できる" "$?" "0"
  # 実際に実行できること（= 登録された文字列がシェルで正しく解釈される）
  jq '.model = "fable"' "$s" > "${SANDBOX}/t33.json" && cp "${SANDBOX}/t33.json" "$s"
  eval "$cmd"
  status=$?
  assert_eq "t33 登録コマンドが実行できる" "$status" "0"
  assert_eq "t33 登録コマンドが実際にフックとして働く" "$(jq -r 'has("model")' "$s")" "false"
  # 対照: クォートしない従来の形は動かない（この修正が必要だったことの確認）
  legacy="bash ${HOME}/.claude/hooks/claude-agents-strip-model.sh"
  eval "$legacy" >/dev/null 2>&1
  status=$?
  assert_ne "t33 クォート無しでは失敗する（対照）" "$status" "0"
}

# 過去の install.sh が書いたクォート無しの登録を、クォート付きへ差し替える
case_t34_install_upgrades_legacy_unquoted() {
  local s legacy
  export HOME="${SANDBOX}/Taro Yamada"
  mkdir -p "$HOME"
  s="${HOME}/.claude/settings.json"
  run_install
  legacy="bash ${HOME}/.claude/hooks/claude-agents-strip-model.sh"
  jq --arg legacy "$legacy" '.hooks.Stop = [{"matcher":"","hooks":[{"type":"command","command":$legacy}]}]' \
    "$s" > "${SANDBOX}/t34.json" && cp "${SANDBOX}/t34.json" "$s"
  run_install
  assert_eq "t34 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t34 修正した旨を表示する" "$INSTALL_OUT" "クォート付きに修正"
  assert_eq "t34 登録は 1 件のまま" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
  assert_eq "t34 クォート付きになっている" \
    "$(registered_hook_commands "$s")" "bash '${HOME}/.claude/hooks/claude-agents-strip-model.sh'"
  run_install
  assert_contains "t34 3 回目はスキップ" "$INSTALL_OUT" "Stop フックは登録済み（スキップ）"
}

# legacy 差し替えが外科的であること。SessionStart・他の Stop エントリ・配列内の
# 非オブジェクト要素を巻き込まないことを検証する（レビュー指摘 F8）。
# ユーザーの手書きフック設定を落とす退行は、これが無いと緑のまま通る。
case_t34b_legacy_replacement_is_surgical() {
  local s legacy before_hooks after_hooks
  export HOME="${SANDBOX}/Taro Yamada"
  mkdir -p "$HOME"
  s="${HOME}/.claude/settings.json"
  run_install
  legacy="bash ${HOME}/.claude/hooks/claude-agents-strip-model.sh"
  jq --arg legacy "$legacy" '
    .hooks = {
      "SessionStart": [{"matcher":"","hooks":[{"type":"command","command":"bash ~/bin/session-start.sh"}]}],
      "Stop": [
        {"matcher":"","hooks":[{"type":"command","command":"bash ~/bin/notify-stop.sh"}]},
        "junk-entry",
        {"matcher":"","hooks":[{"type":"command","command":$legacy},{"type":"command","command":"bash ~/bin/also-me.sh"}]}
      ]
    }' "$s" > "${SANDBOX}/t34b.json" && cp "${SANDBOX}/t34b.json" "$s"
  before_hooks="$(jq -S '.hooks' "$s")"
  run_install
  assert_eq "t34b 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t34b 修正した旨を表示する" "$INSTALL_OUT" "クォート付きに修正"
  after_hooks="$(jq -S '.hooks' "$s")"
  assert_eq "t34b SessionStart は不変" \
    "$(printf '%s' "$after_hooks" | jq -S '.SessionStart')" \
    "$(printf '%s' "$before_hooks" | jq -S '.SessionStart')"
  assert_eq "t34b Stop の要素数は不変" \
    "$(printf '%s' "$after_hooks" | jq '.Stop | length')" "3"
  assert_eq "t34b 他の Stop エントリは不変" \
    "$(printf '%s' "$after_hooks" | jq -S '.Stop[0]')" \
    "$(printf '%s' "$before_hooks" | jq -S '.Stop[0]')"
  assert_eq "t34b 配列内の非オブジェクト要素は不変" \
    "$(printf '%s' "$after_hooks" | jq -r '.Stop[1]')" "junk-entry"
  assert_eq "t34b 同じエントリ内の別コマンドは不変" \
    "$(printf '%s' "$after_hooks" | jq -r '.Stop[2].hooks[1].command')" "bash ~/bin/also-me.sh"
  assert_eq "t34b legacy コマンドだけがクォート付きになる" \
    "$(printf '%s' "$after_hooks" | jq -r '.Stop[2].hooks[0].command')" \
    "bash '${HOME}/.claude/hooks/claude-agents-strip-model.sh'"
  # 差分は legacy コマンドの 1 文字列だけであることを、逆変換して確認する
  assert_eq "t34b 変わったのはその 1 箇所だけ" \
    "$(printf '%s' "$after_hooks" | jq -S --arg cmd "bash '${HOME}/.claude/hooks/claude-agents-strip-model.sh'" --arg legacy "$legacy" \
        '(.Stop[2].hooks[0].command) |= (if . == $cmd then $legacy else . end)')" \
    "$before_hooks"
}

# ---------------------------------------------------------------- 旧インストール

# CLAUDE_CONFIG_DIR を使っている環境に ~/.claude 側の旧インストールが残っている
# 場合、検出して警告するが削除はしない（ユーザー決定: 警告のみ）
case_t35b_warns_about_legacy_install() {
  local custom="${SANDBOX}/xdg/claude" legacy="${HOME}/.claude" ref="${SANDBOX}/ref.json"
  mkdir -p "${legacy}/agents" "${legacy}/hooks"
  ln -s "${REPO_DIR}/agents/auto-router.md" "${legacy}/agents/auto-router.md"
  printf '%s\n' '{"agent":"auto-router","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash '"${legacy}"'/hooks/claude-agents-strip-model.sh"}]}]}}' \
    > "${legacy}/settings.json"
  cp "${legacy}/settings.json" "$ref"
  export CLAUDE_CONFIG_DIR="$custom"
  run_install
  unset CLAUDE_CONFIG_DIR
  assert_eq "t35b 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t35b 旧インストールを知らせる" "$INSTALL_OUT" "旧インストールが残っています"
  assert_contains "t35b symlink の本数を出す" "$INSTALL_OUT" "symlink 1 本"
  assert_contains "t35b Stop 登録も挙げる" "$INSTALL_OUT" "settings.json の Stop フック登録"
  assert_contains "t35b 外すと復活する旨を伝える" "$INSTALL_OUT" "黙って復活します"
  assert_same_bytes "t35b 旧側の settings.json は変更しない" "${legacy}/settings.json" "$ref"
  [ -L "${legacy}/agents/auto-router.md" ] || fail "t35b: 旧側の symlink を消してはいけない"
}

case_t35c_no_warning_without_legacy_install() {
  local custom="${SANDBOX}/xdg/claude"
  export CLAUDE_CONFIG_DIR="$custom"
  run_install
  unset CLAUDE_CONFIG_DIR
  assert_eq "t35c 終了ステータス" "$INSTALL_STATUS" "0"
  assert_not_contains "t35c 旧インストールが無ければ警告しない" "$INSTALL_OUT" "旧インストールが残っています"
}

# CLAUDE_CONFIG_DIR が ~/.claude と「同じディレクトリの別表記」のとき、自分自身を
# 旧インストールと誤警告しないこと（レビュー指摘 FF2）。案内どおりアンインストール
# すると現用の構成を消してしまうので、ここは落としてはいけない。
# 表記ゆれ 1: 末尾スラッシュ
case_t35d_no_false_warning_trailing_slash() {
  export CLAUDE_CONFIG_DIR="${HOME}/.claude/"
  run_install
  unset CLAUDE_CONFIG_DIR
  assert_eq "t35d 終了ステータス" "$INSTALL_STATUS" "0"
  assert_not_contains "t35d 自分自身を旧インストールと呼ばない" "$INSTALL_OUT" "旧インストールが残っています"
  [ -L "${HOME}/.claude/hooks/claude-agents-strip-model.sh" ] || fail "t35d: symlink が張られていない"
}

# 表記ゆれ 2: $HOME 自体が symlink（論理パスと物理パスの食い違い）
case_t35e_no_false_warning_symlinked_home() {
  local real="${SANDBOX}/realhome"
  mkdir -p "$real"
  ln -s "$real" "${SANDBOX}/linkhome"
  export HOME="${SANDBOX}/linkhome"
  export CLAUDE_CONFIG_DIR="${real}/.claude"
  run_install
  unset CLAUDE_CONFIG_DIR
  assert_eq "t35e 終了ステータス" "$INSTALL_STATUS" "0"
  assert_not_contains "t35e 自分自身を旧インストールと呼ばない" "$INSTALL_OUT" "旧インストールが残っています"
  [ -L "${real}/.claude/hooks/claude-agents-strip-model.sh" ] || fail "t35e: symlink が張られていない"
}

# クォート済みと旧クォート無しが併存する環境（手で正しい登録を足して回避した
# ユーザー等）。旧登録を「差し替える」とクォート済みが 2 つになりフックが毎ターン
# 2 回走るので、除去でなければならない（レビュー指摘 FF3）。
case_t34c_removes_legacy_when_current_exists() {
  local s legacy cmd
  export HOME="${SANDBOX}/Taro Yamada"
  mkdir -p "$HOME"
  s="${HOME}/.claude/settings.json"
  run_install
  cmd="$(registered_hook_commands "$s")"
  legacy="bash ${HOME}/.claude/hooks/claude-agents-strip-model.sh"
  # 正しい登録（install.sh が入れたもの）に加えて、旧クォート無しの登録と
  # 無関係な Stop エントリを置く
  jq --arg legacy "$legacy" --arg cmd "$cmd" '
    .hooks.Stop = [
      {"matcher":"","hooks":[{"type":"command","command":"bash ~/bin/notify-stop.sh"}]},
      {"matcher":"","hooks":[{"type":"command","command":$legacy}]},
      {"matcher":"","hooks":[{"type":"command","command":$cmd}]}
    ]' "$s" > "${SANDBOX}/t34c.json" && cp "${SANDBOX}/t34c.json" "$s"
  run_install
  assert_eq "t34c 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t34c 旧登録を削除した旨を表示する" "$INSTALL_OUT" "旧登録を削除"
  assert_eq "t34c 登録は 1 件だけ（2 重登録にしない）" \
    "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
  assert_eq "t34c 残るのはクォート付きの方" "$(registered_hook_commands "$s")" "$cmd"
  assert_eq "t34c 無関係の Stop エントリは残る" \
    "$(jq -r '[.hooks.Stop[] | objects | .hooks[] | objects | .command] | map(select(contains("notify-stop"))) | length' "$s")" "1"
  assert_eq "t34c 空になったエントリは落ちる" "$(jq '.hooks.Stop | length' "$s")" "2"
  run_install
  assert_contains "t34c 次の実行はスキップ" "$INSTALL_OUT" "Stop フックは登録済み（スキップ）"
}

# シングルクォートやシェルのメタ文字を含むホームでも、登録コマンドが安全に
# 実行できること（レビュー指摘 FF7-a）。クォートが壊れていれば $(touch pwned) が
# 実行されるので、それが起きないことを直接見る。
case_t34d_quotes_metacharacter_path() {
  local s cmd
  export HOME="${SANDBOX}/Ta'ro \$(touch pwned) Yamada"
  mkdir -p "$HOME"
  s="${HOME}/.claude/settings.json"
  run_install
  assert_eq "t34d 終了ステータス" "$INSTALL_STATUS" "0"
  cmd="$(registered_hook_commands "$s")"
  assert_contains "t34d シングルクォートがエスケープされている" "$cmd" "'\\''"
  jq '.model = "fable"' "$s" > "${SANDBOX}/t34d.json" && cp "${SANDBOX}/t34d.json" "$s"
  /bin/sh -c "$cmd"
  assert_eq "t34d POSIX sh で実行できる" "$?" "0"
  assert_eq "t34d 実際にフックとして働く" "$(jq -r 'has("model")' "$s")" "false"
  assert_file_absent "t34d コマンド置換が実行されない" "${SANDBOX}/pwned"
  assert_file_absent "t34d コマンド置換が実行されない（HOME 側）" "${HOME}/pwned"
}

# 手動で ~ 表記で登録している場合は触らない（二重登録もしない）
case_t35_install_keeps_manual_registration() {
  local s
  mkdir -p "${HOME}/.claude"
  printf '%s\n' '{"agent":"x","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/hooks/claude-agents-strip-model.sh"}]}]}}' \
    > "${HOME}/.claude/settings.json"
  s="${HOME}/.claude/settings.json"
  run_install
  assert_eq "t35 終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t35 登録は 1 件のまま" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
  assert_contains "t35 手動登録はそのまま" "$(registered_hook_commands "$s")" '~/.claude/hooks'
  assert_contains "t35 スキップ表示" "$INSTALL_OUT" "Stop フックは登録済み（スキップ）"
}

# ---------------------------------------------------------------- symlink

case_t36_install_settings_symlink() {
  local real="${SANDBOX}/dotfiles/settings.json" link="${HOME}/.claude/settings.json"
  write_settings "$real" '{"canary":"keep-me"}'
  mkdir -p "${HOME}/.claude"
  ln -s "$real" "$link"
  run_install
  assert_eq "t36 終了ステータス" "$INSTALL_STATUS" "0"
  [ -L "$link" ] || fail "t36: symlink が実ファイルに置き換わった"
  assert_eq "t36 実体に書かれる" "$(jq -r '.agent' "$real")" "auto-router"
  assert_eq "t36 既存キーは保持" "$(jq -r '.canary' "$real")" "keep-me"
  assert_eq "t36 実体のパーミッション保持" "$(file_mode "$real")" "644"
  assert_file_exists "t36 バックアップは ~/.claude 側に置く" \
    "$(ls "${HOME}/.claude"/settings.json.bak.* 2>/dev/null | head -1)"
  assert_eq "t36 dotfiles 側にバックアップを作らない" \
    "$(ls "${SANDBOX}/dotfiles"/settings.json.bak.* 2>/dev/null | wc -l | tr -d ' ')" "0"
}

case_t37_install_settings_symlink_relative_chain() {
  local real="${HOME}/.claude/dotfiles/real.json" link="${HOME}/.claude/settings.json"
  write_settings "$real" '{"canary":"keep-me"}'
  ln -s "dotfiles/real.json" "${HOME}/.claude/hop.json"
  ln -s "hop.json" "$link"
  run_install
  assert_eq "t37 終了ステータス" "$INSTALL_STATUS" "0"
  [ -L "$link" ] || fail "t37: symlink が実ファイルに置き換わった"
  [ -L "${HOME}/.claude/hop.json" ] || fail "t37: 中間 symlink が置き換わった"
  assert_eq "t37 実体に書かれる" "$(jq -r '.agent' "$real")" "auto-router"
  assert_eq "t37 既存キーは保持" "$(jq -r '.canary' "$real")" "keep-me"
}

# symlink ループでもハングせず、警告を出して残りのステップは続行する
case_t38_install_settings_symlink_loop() {
  local link="${HOME}/.claude/settings.json"
  mkdir -p "${HOME}/.claude"
  ln -s "${HOME}/.claude/loop-b" "$link"
  ln -s "$link" "${HOME}/.claude/loop-b"
  run_install
  assert_eq "t38 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t38 解決不能を警告する" "$INSTALL_OUT" "実体パスを解決できませんでした"
  assert_contains "t38 以降のステップは続行する" "$INSTALL_OUT" "aliases:"
  [ -L "${HOME}/.claude/hooks/claude-agents-strip-model.sh" ] || fail "t38: symlink 配置は行われるべき"
}

case_t39_install_settings_symlink_broken() {
  local link="${HOME}/.claude/settings.json"
  mkdir -p "${HOME}/.claude"
  ln -s "${SANDBOX}/nowhere/settings.json" "$link"
  run_install
  assert_eq "t39 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t39 解決不能を警告する" "$INSTALL_OUT" "実体パスを解決できませんでした"
  assert_contains "t39 以降のステップは続行する" "$INSTALL_OUT" "aliases:"
  assert_file_absent "t39 リンク先を作らない" "${SANDBOX}/nowhere/settings.json"
}

# ---------------------------------------------------------------- 書けない設定

# settings.json の実体ディレクトリが読み取り専用のとき、途中で死なずに
# 警告して続行する（過去に cp のバックアップが無防備で部分適用になった）
case_t40_install_readonly_settings_dir() {
  local real="${SANDBOX}/ro/settings.json" link="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json"
  write_settings "$real" '{"canary":"keep-me"}'
  cp "$real" "$ref"
  mkdir -p "${HOME}/.claude"
  ln -s "$real" "$link"
  chmod 0555 "${SANDBOX}/ro"
  run_install
  chmod 0755 "${SANDBOX}/ro"
  assert_eq "t40 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t40 一時ファイル作成失敗を警告する" "$INSTALL_OUT" "一時ファイルの作成に失敗しました"
  assert_contains "t40 エイリアス登録まで到達する" "$INSTALL_OUT" "aliases:"
  assert_same_bytes "t40 実体は変更されない" "$real" "$ref"
}

# ---------------------------------------------------------------- エイリアス

case_t41_alias_old_block_warns() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --agent orchestrator'
alias ccd='claude --model fable --agent claude --effort high'
alias ccw='claude -w'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t41 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t41 古いブロックを警告する" "$INSTALL_OUT" "--effort max がありません"
}

case_t42_alias_current_block_quiet() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --agent orchestrator --effort max'
alias ccd='claude --model fable --agent claude --effort high'
alias ccw='claude -w'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t42 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t42 スキップ表示" "$INSTALL_OUT" "aliases: 設定済み（スキップ）"
  assert_not_contains "t42 警告は出ない" "$INSTALL_OUT" "--effort max がありません"
}

# ---------------------------------------------------------------- README

# README のアンインストール手順を README から抜き出してそのまま実行する。
# 手順が 3 箇所目の symlink 解決ロジックを手写ししているので、README だけが
# 古くなる／壊れるのを機械的に防ぐ。
extract_uninstall_snippet() { # 出力先
  awk '
    /^## アンインストール/ { found = 1; next }
    found && /^```bash$/ { inblock = 1; next }
    inblock && /^```$/ { exit }
    inblock { print }
  ' "${REPO_DIR}/README.md" > "$1"
  [ -s "$1" ] || return 1
  grep -q '^cd /path/to/claude-agents$' "$1" || return 1
  # プレースホルダを実リポジトリへ差し替える
  sed "s|^cd /path/to/claude-agents\$|cd '${REPO_DIR}'|" "$1" > "${1}.run"
  mv "${1}.run" "$1"
  ! grep -q '/path/to/claude-agents' "$1"
}

case_t43_readme_uninstall_roundtrip() {
  local s="${HOME}/.claude/settings.json" snippet="${SANDBOX}/uninstall.sh" status
  local lock="${HOME}/.claude/.strip-model.lock" retired
  run_install
  assert_eq "t43 install の終了ステータス" "$INSTALL_STATUS" "0"
  # ロック残骸の掃除も手順に含まれること（フック側の回収は次に書き込みが必要に
  # なるまで走らないため。レビュー指摘 FF6）
  retired="${HOME}/.claude/.strip-model.lock.stale.4242-1-999"
  mkdir "$lock" "$retired"
  printf 'x\n' > "${lock}/token"
  printf 'y\n' > "${retired}/token"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t43: README からアンインストール手順を抽出できない（見出し・コードブロック・cd 行を確認）"
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  assert_eq "t43 アンインストールの終了ステータス" "$status" "0"
  assert_eq "t43 stderr は空" "$(cat "${SANDBOX}/uninstall.err")" ""
  assert_eq "t43 agent が消える" "$(jq -r 'has("agent")' "$s")" "false"
  assert_eq "t43 effortLevel が消える" "$(jq -r 'has("effortLevel")' "$s")" "false"
  assert_eq "t43 Stop 登録が消える" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "0"
  assert_eq "t43 agents の symlink が消える" \
    "$(find "${HOME}/.claude/agents" -type l 2>/dev/null | wc -l | tr -d ' ')" "0"
  assert_eq "t43 hooks の symlink が消える" \
    "$(find "${HOME}/.claude/hooks" -type l 2>/dev/null | wc -l | tr -d ' ')" "0"
  assert_eq "t43 skills の symlink が消える" \
    "$(find "${HOME}/.claude/skills" -type l 2>/dev/null | wc -l | tr -d ' ')" "0"
  assert_eq "t43 bin の symlink が消える" \
    "$(find "${HOME}/.claude/bin" -type l 2>/dev/null | wc -l | tr -d ' ')" "0"
  assert_file_absent "t43 ロックを掃除する" "$lock"
  assert_file_absent "t43 退避ディレクトリを掃除する" "$retired"
}

# settings.json が symlink ループのとき、README の手順はハングせず中断する
# （README 版だけループ検出が無く、コピペした対話シェルが固まっていた）
case_t44_readme_uninstall_symlink_loop() {
  local link="${HOME}/.claude/settings.json" snippet="${SANDBOX}/uninstall.sh" status
  run_install
  # インストール後に settings.json が symlink ループへ差し替わった状況
  rm -f "$link"
  ln -s "${HOME}/.claude/loop-b" "$link"
  ln -s "$link" "${HOME}/.claude/loop-b"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t44: README からアンインストール手順を抽出できない"
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  assert_eq "t44 手順全体は続行して終了する" "$status" "0"
  assert_contains "t44 ループを検出して中断する" "$(cat "${SANDBOX}/uninstall.err")" "20 段"
  assert_eq "t44 隠しファイルを残さない" \
    "$(ls -a "${HOME}/.claude" 2>/dev/null | grep -c 'settings.json.uninstall' | tr -d ' ')" "0"
  assert_eq "t44 symlink 削除は続行される" \
    "$(find "${HOME}/.claude/agents" -type l 2>/dev/null | wc -l | tr -d ' ')" "0"
}

# CLAUDE_CONFIG_DIR を設定している環境でも、settings.json だけでなく symlink 削除
# まで追従すること（レビュー指摘 F6: 手順 1 だけが自動解決で、手順 2 の find は
# ~/.claude 直書きだった。find は対象ゼロでも成功するので、symlink が全部残った
# まま「成功したように見える」）
case_t46_readme_uninstall_claude_config_dir() {
  local custom="${SANDBOX}/xdg/claude" snippet="${SANDBOX}/uninstall.sh" status
  export CLAUDE_CONFIG_DIR="$custom"
  run_install
  assert_eq "t46 install の終了ステータス" "$INSTALL_STATUS" "0"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t46: README からアンインストール手順を抽出できない"
    unset CLAUDE_CONFIG_DIR
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  unset CLAUDE_CONFIG_DIR
  assert_eq "t46 アンインストールの終了ステータス" "$status" "0"
  assert_eq "t46 stderr は空" "$(cat "${SANDBOX}/uninstall.err")" ""
  assert_eq "t46 agent が消える" "$(jq -r 'has("agent")' "${custom}/settings.json")" "false"
  assert_eq "t46 Stop 登録が消える" "$(registered_hook_commands "${custom}/settings.json" | wc -l | tr -d ' ')" "0"
  assert_eq "t46 CLAUDE_CONFIG_DIR 側の symlink が消える" \
    "$(find "$custom" -type l 2>/dev/null | wc -l | tr -d ' ')" "0"
  assert_contains "t46 消したものを表示する" "$(cat "${SANDBOX}/uninstall.out")" "auto-router.md"
}

# jq が失敗しても隠しファイルを残さない（README 版は残していた）
case_t45_readme_uninstall_broken_json() {
  local s="${HOME}/.claude/settings.json" snippet="${SANDBOX}/uninstall.sh" ref="${SANDBOX}/ref.json" status
  run_install
  # インストール後に settings.json が壊れた（手で編集した等）状況
  write_settings "$s" '{"agent": broken'
  cp "$s" "$ref"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t45: README からアンインストール手順を抽出できない"
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  assert_eq "t45 手順全体は続行して終了する" "$status" "0"
  assert_same_bytes "t45 壊れた JSON は変更しない" "$s" "$ref"
  assert_contains "t45 失敗を伝える" "$(cat "${SANDBOX}/uninstall.err")" "jq に失敗"
  assert_eq "t45 隠しファイルを残さない" \
    "$(ls -a "${HOME}/.claude" 2>/dev/null | grep -c 'settings.json.uninstall' | tr -d ' ')" "0"
}
