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
  assert_contains "t33 パスがクォート/エスケープされている" "$cmd" '\ '
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
  assert_contains "t34 クォート付きになっている" "$(registered_hook_commands "$s")" '\ '
  run_install
  assert_contains "t34 3 回目はスキップ" "$INSTALL_OUT" "Stop フックは登録済み（スキップ）"
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
  run_install
  assert_eq "t43 install の終了ステータス" "$INSTALL_STATUS" "0"
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
