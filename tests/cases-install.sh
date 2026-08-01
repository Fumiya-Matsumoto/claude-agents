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
  assert_eq "t30 permissions.defaultMode が設定される" "$(jq -r '.permissions.defaultMode' "$s")" "auto"
  assert_eq "t30 Stop フックが 1 件登録される" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
  assert_contains "t30 登録メッセージ" "$INSTALL_OUT" "Stop フックに claude-agents-strip-model.sh を登録"
  assert_contains "t30 エイリアス追加" "$INSTALL_OUT" "aliases:"
  assert_contains "t30 rc にマーカー" "$(cat "${HOME}/.bashrc")" ">>> claude-agents aliases >>>"
  # claude --help の -w, --worktree [name] は値を省略できる引数を取るため、
  # --permission-mode auto が -w より後ろにあると worktree 名の positional
  # prompt として食われてしまう（実際の退行）。正本ブロックの ccw 行で
  # --permission-mode auto が -w より前にあることを担保する。
  local ccw_line
  ccw_line="$(grep -F 'alias ccw=' "${HOME}/.bashrc")"
  case "$ccw_line" in
    *'--permission-mode auto'*'-w'*) ;;
    *) fail "t30: ccw エイリアスで --permission-mode auto が -w より前にない: $ccw_line" ;;
  esac
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

# インストール前から permissions.allow 等の兄弟キーがある場合、
# permissions.defaultMode の設定がそれらを消さないこと（jq のパス代入が
# 兄弟キーを保つことの回帰検出。effortLevel と同じ「元の値を上書き」表示に
# なることも合わせて確認する）
case_t47_default_mode_preserves_siblings() {
  local s="${HOME}/.claude/settings.json"
  write_settings "$s" '{"permissions":{"allow":["Bash(ls:*)"],"defaultMode":"plan"}}'
  run_install
  assert_eq "t47 終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t47 defaultMode が auto になる" "$(jq -r '.permissions.defaultMode' "$s")" "auto"
  assert_eq "t47 allow は残る" "$(jq -c '.permissions.allow' "$s")" '["Bash(ls:*)"]'
  assert_contains "t47 元の値を上書きした旨を表示する" "$INSTALL_OUT" '元の値 "plan" を上書き'
}

# .permissions が非オブジェクト（配列）のとき、jq '.permissions.defaultMode = ...'
# を直接叩くと生の型エラーが stderr に出る（親切な警告と重複して読みにくい）。
# 書き込み前に型を判定し、非オブジェクトのときは専用の警告で継続すること・
# 生エラーを出さないこと・settings.json の他の値を壊さないこと・以降の
# ステップ（agent 設定・エイリアス登録）に到達することを確認する（受入条件 E）。
case_t50_non_object_permissions_survives() {
  local s="${HOME}/.claude/settings.json"
  write_settings "$s" '{"permissions":["Bash(ls:*)"],"canary":"keep-me"}'
  run_install
  assert_eq "t50 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t50 専用の警告が出る" "$INSTALL_OUT" 'permissions" がオブジェクトではありません'
  assert_eq "t50 permissions の値は壊れない" "$(jq -c '.permissions' "$s")" '["Bash(ls:*)"]'
  assert_eq "t50 canary は残る" "$(jq -r '.canary' "$s")" "keep-me"
  assert_eq "t50 agent が設定される" "$(jq -r '.agent' "$s")" "auto-router"
  assert_contains "t50 エイリアス登録まで到達する" "$INSTALL_OUT" "aliases:"
  assert_eq "t50 stderr に jq の生エラーが出ない" "$INSTALL_ERR" ""
  assert_eq "t50 一時ファイルの残骸が無い" \
    "$(find "${HOME}/.claude" -maxdepth 1 -name '.settings.json.install.*' 2>/dev/null | wc -l | tr -d ' ')" "0"
}

# CLAUDE_AGENTS_SET_DEFAULT_MODE=0 で permissions.defaultMode の書き込みだけを
# スキップできること（他の設定（agent / effortLevel）は影響を受けない）
# （受入条件 D）
case_t51_default_mode_opt_out() {
  local s="${HOME}/.claude/settings.json"
  export CLAUDE_AGENTS_SET_DEFAULT_MODE=0
  run_install
  unset CLAUDE_AGENTS_SET_DEFAULT_MODE
  assert_eq "t51 終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t51 permissions.defaultMode は設定されない" "$(jq -r 'has("permissions")' "$s")" "false"
  assert_contains "t51 スキップした旨を表示する" "$INSTALL_OUT" "CLAUDE_AGENTS_SET_DEFAULT_MODE=0"
  assert_eq "t51 agent は設定される" "$(jq -r '.agent' "$s")" "auto-router"
  assert_eq "t51 effortLevel は設定される" "$(jq -r '.effortLevel' "$s")" "xhigh"
  # permissions.defaultMode のオプトアウトは Stop フック登録の if/else の外に
  # あるため巻き添えにならないはずだが、その不変条件がテストで固定されていな
  # かった（オプトアウトしても Stop フックは登録されることを確認する）
  assert_eq "t51 Stop フックは登録される" "$(registered_hook_commands "$s" | wc -l | tr -d ' ')" "1"
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
  assert_contains "t41 permission-mode の欠落も警告する" "$INSTALL_OUT" "--permission-mode auto がありません"
}

case_t42_alias_current_block_quiet() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --permission-mode auto --agent orchestrator --effort max'
alias ccd='claude --permission-mode auto --model fable --agent claude --effort high'
alias ccw='claude --permission-mode auto -w'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t42 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t42 スキップ表示" "$INSTALL_OUT" "aliases: 設定済み（スキップ）"
  assert_not_contains "t42 警告は出ない（effort）" "$INSTALL_OUT" "--effort max がありません"
  assert_not_contains "t42 警告は出ない（permission-mode）" "$INSTALL_OUT" "--permission-mode auto がありません"
}

# --effort max だけを備えた「一世代前」のブロック。effort の警告は出さず、
# permission-mode の警告だけを出し分けられることを確かめる。両方欠けた t41 と
# 合わせて、フラグごとに独立して判定していることの対照になる。
case_t42b_alias_missing_permission_mode_only() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --agent orchestrator --effort max'
alias ccd='claude --model fable --agent claude --effort high'
alias ccw='claude -w'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t42b 終了ステータス" "$INSTALL_STATUS" "0"
  assert_contains "t42b permission-mode の欠落を警告する" "$INSTALL_OUT" "--permission-mode auto がありません"
  assert_not_contains "t42b effort は警告しない" "$INSTALL_OUT" "--effort max がありません"
  # 正本ブロックと警告時の置換用ブロックのドリフト検出（cco / ccd / ccw の
  # 3 行とも、置換用の案内が正本と文字列一致していることを固定する）
  assert_contains "t42b 置換用ブロックを提示する（cco）" "$INSTALL_OUT" "alias cco='claude --permission-mode auto --agent orchestrator --effort max'"
  assert_contains "t42b 置換用ブロックを提示する（ccd）" "$INSTALL_OUT" "alias ccd='claude --permission-mode auto --model fable --agent claude --effort high'"
  assert_contains "t42b 置換用ブロックを提示する（ccw）" "$INSTALL_OUT" "alias ccw='claude --permission-mode auto -w'"
}

# --effort max だけを既に持つ cco と異なり、ccd / ccw の 2 行だけが古い
# （--permission-mode auto を含まない）ブロック。cco は警告せず、ccd / ccw
# だけを行単位で出し分けられることを確かめる（受入条件 B）。
case_t42c_alias_ccd_ccw_stale() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --agent orchestrator --effort max --permission-mode auto'
alias ccd='claude --model fable --agent claude --effort high'
alias ccw='claude -w'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t42c 終了ステータス" "$INSTALL_STATUS" "0"
  assert_not_contains "t42c cco の --effort max は警告しない" "$INSTALL_OUT" "cco エイリアスに --effort max がありません"
  assert_not_contains "t42c cco の --permission-mode auto は警告しない" "$INSTALL_OUT" "cco エイリアスに --permission-mode auto がありません"
  assert_contains "t42c ccd の欠落を警告する" "$INSTALL_OUT" "ccd エイリアスに --permission-mode auto がありません"
  # ccw の判定は単純な有無ではなく引数順の検査なので、警告文言も専用の形になる
  assert_contains "t42c ccw の欠落を警告する" "$INSTALL_OUT" "ccw エイリアスの引数順が古い、または --permission-mode auto がありません"
  # 正本ブロックと警告時の置換用ブロックのドリフト検出（cco / ccd / ccw の
  # 3 行とも、置換用の案内が正本と文字列一致していることを固定する）
  assert_contains "t42c 置換用ブロックを提示する（cco）" "$INSTALL_OUT" "alias cco='claude --permission-mode auto --agent orchestrator --effort max'"
  assert_contains "t42c 置換用ブロックを提示する（ccd）" "$INSTALL_OUT" "alias ccd='claude --permission-mode auto --model fable --agent claude --effort high'"
  assert_contains "t42c 置換用ブロックを提示する（ccw）" "$INSTALL_OUT" "alias ccw='claude --permission-mode auto -w'"
}

# ccw の旧い引数順（-w が --permission-mode auto より前）を入力とする。
# --permission-mode auto の有無だけを見る単純な部分文字列検査だと、この壊れた
# 順序を「現行」と誤判定してしまう（受入条件 A）。順序の警告が出ることと、
# cco / ccd は警告しないこと、置換用ブロックが提示されることを固定する。
case_t42d_alias_ccw_wrong_order() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --permission-mode auto --agent orchestrator --effort max'
alias ccd='claude --permission-mode auto --model fable --agent claude --effort high'
alias ccw='claude -w --permission-mode auto'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t42d 終了ステータス" "$INSTALL_STATUS" "0"
  assert_not_contains "t42d cco は警告しない" "$INSTALL_OUT" "cco エイリアスに"
  assert_not_contains "t42d ccd は警告しない" "$INSTALL_OUT" "ccd エイリアスに"
  assert_contains "t42d ccw の引数順を警告する" "$INSTALL_OUT" "ccw エイリアスの引数順が古い、または --permission-mode auto がありません"
  assert_contains "t42d 置換用ブロックを提示する" "$INSTALL_OUT" "alias ccw='claude --permission-mode auto -w'"
}

# ccd から --agent claude だけを落とした rc。--agent claude が無いと D ペインは
# 「Fable の上に auto-router を着せた」セッションになる（README の「ペイン運用」
# を参照）ため、他のフラグと独立に検査されることを確かめる（受入条件 B）。
case_t42e_alias_ccd_missing_agent_claude() {
  cat > "${HOME}/.bashrc" <<'EOF'
# >>> claude-agents aliases >>>
alias cco='claude --permission-mode auto --agent orchestrator --effort max'
alias ccd='claude --permission-mode auto --model fable --effort high'
alias ccw='claude --permission-mode auto -w'
# <<< claude-agents aliases <<<
EOF
  run_install
  assert_eq "t42e 終了ステータス" "$INSTALL_STATUS" "0"
  assert_not_contains "t42e cco は警告しない" "$INSTALL_OUT" "cco エイリアスに"
  assert_not_contains "t42e ccd の permission-mode は警告しない" "$INSTALL_OUT" "ccd エイリアスに --permission-mode auto がありません"
  assert_not_contains "t42e ccw は警告しない" "$INSTALL_OUT" "ccw エイリアスの引数順が古い"
  assert_contains "t42e ccd の --agent claude 欠落を警告する" "$INSTALL_OUT" "ccd エイリアスに --agent claude がありません"
  assert_contains "t42e 置換用ブロックを提示する" "$INSTALL_OUT" "alias ccd='claude --permission-mode auto --model fable --agent claude --effort high'"
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
  assert_eq "t43 permissions.defaultMode が消える" \
    "$(jq -r '(.permissions // {}) | has("defaultMode")' "$s")" "false"
  # t43 の入力はまっさらな HOME で permissions に defaultMode 以外の兄弟キーが
  # 無いため、defaultMode 削除の結果 .permissions ごと消えるはず。「キーだけ
  # 消えた」と「.permissions ごと消えた」を明示的に区別する（受入条件 G）
  assert_eq "t43 兄弟キーが無いため permissions ごと消える" \
    "$(jq -r 'has("permissions")' "$s")" "false"
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

# README が約束する 2 性質のうち「兄弟キーは残す」を検証する。t43 は
# まっさらな HOME で兄弟キーが 1 つも無いため、この性質を区別できない
# （受入条件 G）
case_t48_uninstall_preserves_permission_siblings() {
  local s="${HOME}/.claude/settings.json" snippet="${SANDBOX}/uninstall.sh" status
  write_settings "$s" '{"permissions":{"allow":["Bash(ls:*)"],"deny":["Read(./.env)"]}}'
  run_install
  assert_eq "t48 install の終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t48 defaultMode が auto になる" "$(jq -r '.permissions.defaultMode' "$s")" "auto"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t48: README からアンインストール手順を抽出できない"
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  assert_eq "t48 アンインストールの終了ステータス" "$status" "0"
  assert_eq "t48 stderr は空" "$(cat "${SANDBOX}/uninstall.err")" ""
  assert_eq "t48 defaultMode だけ消える" "$(jq -r '.permissions | has("defaultMode")' "$s")" "false"
  assert_eq "t48 allow は残る" "$(jq -c '.permissions.allow' "$s")" '["Bash(ls:*)"]'
  assert_eq "t48 deny は残る" "$(jq -c '.permissions.deny' "$s")" '["Read(./.env)"]'
}

# README が約束するもう 1 つの性質「空になった場合のみ .permissions 自体も
# 消す」を、まっさらな HOME（defaultMode 以外に兄弟キーが無い＝インストール
# 前は permissions キー自体が無かった）で検証する（受入条件 G）
case_t49_uninstall_drops_empty_permissions() {
  local s="${HOME}/.claude/settings.json" snippet="${SANDBOX}/uninstall.sh" status
  run_install
  assert_eq "t49 install の終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t49 defaultMode が auto になる" "$(jq -r '.permissions.defaultMode' "$s")" "auto"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t49: README からアンインストール手順を抽出できない"
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  assert_eq "t49 アンインストールの終了ステータス" "$status" "0"
  assert_eq "t49 stderr は空" "$(cat "${SANDBOX}/uninstall.err")" ""
  assert_eq "t49 permissions キー自体が消える" "$(jq -r 'has("permissions")' "$s")" "false"
}

# t49 は permissions キー自体が無い入力だった。ここではインストール前から
# {"permissions":{}}（空オブジェクト）が置かれていた入力で同じ性質（削除の
# 結果 .permissions が空になったら .permissions 自体も消す）を検証する
# （受入条件 E3。README がこの挙動を明記している一方、その入力のケースが
# 存在しなかった）
case_t52_uninstall_drops_preexisting_empty_permissions() {
  local s="${HOME}/.claude/settings.json" snippet="${SANDBOX}/uninstall.sh" status
  write_settings "$s" '{"permissions":{}}'
  run_install
  assert_eq "t52 install の終了ステータス" "$INSTALL_STATUS" "0"
  assert_eq "t52 defaultMode が auto になる" "$(jq -r '.permissions.defaultMode' "$s")" "auto"
  if ! extract_uninstall_snippet "$snippet"; then
    fail "t52: README からアンインストール手順を抽出できない"
    return
  fi
  assert_sandboxed_home
  bash "$snippet" >"${SANDBOX}/uninstall.out" 2>"${SANDBOX}/uninstall.err"
  status=$?
  assert_eq "t52 アンインストールの終了ステータス" "$status" "0"
  assert_eq "t52 stderr は空" "$(cat "${SANDBOX}/uninstall.err")" ""
  assert_eq "t52 permissions キー自体が消える" "$(jq -r 'has("permissions")' "$s")" "false"
}
