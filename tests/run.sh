#!/usr/bin/env bash
#
# hooks/claude-agents-strip-model.sh と install.sh と README の
# アンインストール手順に対する回帰テスト。
#
# 1 コマンド（bash tests/run.sh）で全件実行する。ネットワーク不要・べき等。
# 各ケースは mktemp -d で作った隔離 HOME の中だけで動き、実際の ~/.claude には
# 触れない（HOME を書き換えても届かないコマンドが混じっていないかは
# assert_sandboxed_home で毎回確認する）。
#
# 個別実行: bash tests/run.sh t01 t16   （ケース ID の前方一致）
#
# なぜこのテストがあるか: このフックはユーザーのグローバル設定を毎ターン
# 破壊的に書き換える。過去に (a) BSD/GNU の stat フォールバック順の取り違え、
# (b) "agent" キーが無い環境で毎ターン一時ファイルとロックを作り続ける退行、
# (c) 読み取り専用ディレクトリで install.sh が途中死にして部分適用で終わる、
# が実際に混入しており、いずれも機械的に検出できる種類の欠陥だった。
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${REPO_DIR}/hooks/claude-agents-strip-model.sh"
INSTALL="${REPO_DIR}/install.sh"
ORIG_PATH="$PATH"
REAL_JQ="$(command -v jq || true)"
REAL_STAT="$(command -v stat || true)"
# 本物の stat が GNU coreutils か BSD か。GNU stat スタブ（t15）が本物へ委譲
# するときの渡し方を変えるために使う（GNU ホストで -f を渡すと --file-system と
# 解釈されてスタブ自体が壊れるため）
if "$REAL_STAT" --version 2>/dev/null | grep -q GNU; then
  REAL_STAT_IS_GNU=yes
else
  REAL_STAT_IS_GNU=no
fi

if [ -z "$REAL_JQ" ]; then
  echo "jq が必要です（テストは jq 前提のフックを検証する）" >&2
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
FAILED_CASES=""
CASE_FAILED=0
CASE_ID=""

# ---------------------------------------------------------------- assert 群

fail() {
  CASE_FAILED=1
  echo "    ✗ $*"
}

assert_eq() { # label actual expected
  if [ "$2" != "$3" ]; then
    fail "$1: expected [$3] but got [$2]"
  fi
}

assert_ne() { # label actual notexpected
  if [ "$2" = "$3" ]; then
    fail "$1: expected something other than [$3]"
  fi
}

assert_contains() { # label haystack needle
  case "$2" in
    *"$3"*) ;;
    *) fail "$1: [$2] does not contain [$3]" ;;
  esac
}

assert_not_contains() { # label haystack needle
  case "$2" in
    *"$3"*) fail "$1: [$2] unexpectedly contains [$3]" ;;
  esac
}

assert_file_exists() { # label path
  [ -e "$2" ] || fail "$1: $2 が存在しない"
}

assert_file_absent() { # label path
  [ -e "$2" ] && fail "$1: $2 が残っている"
  return 0
}

assert_same_bytes() { # label file expected_file
  cmp -s "$2" "$3" || fail "$1: $2 の内容が変化した"
}

# フックが settings.json に触れていないこと（inode・mtime・サイズが不変）
assert_unchanged() { # label file saved_fingerprint
  local now
  now="$(fingerprint "$2")"
  assert_eq "$1" "$now" "$3"
}

# ロック・一時ファイルの後始末
assert_clean() { # label config_dir settings_dir
  local leftovers
  assert_file_absent "$1: ロックが残っている" "${2}/.strip-model.lock"
  leftovers="$(ls -d "${3}"/.settings.json.strip-model.* 2>/dev/null || true)"
  [ -z "$leftovers" ] || fail "$1: 一時ファイルが残っている: $leftovers"
  leftovers="$(ls -d "${2}"/.strip-model.lock.stale.* 2>/dev/null || true)"
  [ -z "$leftovers" ] || fail "$1: 奪取用の退避ディレクトリが残っている: $leftovers"
}

# ---------------------------------------------------------------- ヘルパ

# mtime（秒）・サイズ・inode。GNU の `stat -f` は --file-system と解釈される
# ため GNU の -c を先に試す（フック本体と同じ順序）
fingerprint() {
  "$REAL_STAT" -c '%Y %s %i' "$1" 2>/dev/null || "$REAL_STAT" -f '%m %z %i' "$1" 2>/dev/null
}

file_mode() {
  "$REAL_STAT" -c '%a' "$1" 2>/dev/null || "$REAL_STAT" -f '%Lp' "$1" 2>/dev/null
}

write_settings() { # path json
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  chmod 0644 "$1"
}

DEFAULT_SETTINGS='{
  "agent": "auto-router",
  "model": "fable",
  "effortLevel": "high",
  "canary": "keep-me"
}'

run_hook() { # 追加の環境変数は呼び出し側で export しておく
  HOOK_ERR_FILE="${SANDBOX}/hook.stderr"
  bash "$HOOK" >"${SANDBOX}/hook.stdout" 2>"$HOOK_ERR_FILE"
  HOOK_STATUS=$?
  HOOK_OUT="$(cat "${SANDBOX}/hook.stdout")"
  HOOK_ERR="$(cat "$HOOK_ERR_FILE")"
  return 0
}

# フックは「いかなる経路でも非ゼロ終了しない」が不変条件
assert_hook_ok() { # label
  assert_eq "$1: 終了ステータス" "$HOOK_STATUS" "0"
}

assert_sandboxed_home() {
  case "${HOME:-}" in
    "${SANDBOX}"/*) ;;
    *) echo "FATAL: HOME が sandbox の外を指している (${HOME:-unset})" >&2; exit 99 ;;
  esac
}

# PATH の先頭に置くスタブ用ディレクトリ
stub_dir() {
  mkdir -p "${SANDBOX}/stubs"
  printf '%s\n' "${SANDBOX}/stubs"
}

# ---------------------------------------------------------------- ランナー

run_case() { # id description function
  local id="$1" desc="$2" fn="$3" i
  if [ "$#" -gt 3 ]; then shift 3; fi
  if [ -n "${FILTER:-}" ]; then
    local matched=0
    for i in $FILTER; do
      case "$id" in "$i"*) matched=1 ;; esac
    done
    [ "$matched" -eq 1 ] || return 0
  fi
  CASE_ID="$id"
  CASE_FAILED=0
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/claude-agents-tests.XXXXXX")"
  export HOME="${SANDBOX}/home"
  mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR CLAUDE_AGENTS_STRIP_MODEL CLAUDE_AGENTS_SET_DEFAULT_MODE
  export PATH="$ORIG_PATH"
  export SHELL="/bin/bash"
  cd "$SANDBOX" || exit 99

  "$fn"

  cd "$REPO_DIR" || exit 99
  # 読み取り専用ディレクトリを作るケースがあるので戻してから消す
  chmod -R u+rwX "$SANDBOX" 2>/dev/null
  rm -rf "$SANDBOX"

  if [ "$CASE_FAILED" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  ok   ${id} ${desc}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_CASES="${FAILED_CASES}${id} ${desc}"$'\n'
    echo "  FAIL ${id} ${desc}"
  fi
}

# ---------------------------------------------------------------- 実行

FILTER="${*:-}"

# shellcheck source=tests/cases-hook.sh
. "${REPO_DIR}/tests/cases-hook.sh"
# shellcheck source=tests/cases-install.sh
. "${REPO_DIR}/tests/cases-install.sh"

echo "hooks/claude-agents-strip-model.sh"
run_case t01 "1 回で正規化し、2 回目は書き込まない" case_t01_converge
run_case t02 "agent キーが無い settings.json に触れない（ロック・一時ファイルも作らない）" case_t02_no_agent_key
run_case t03 "壊れた JSON をバイト単位で放置する" case_t03_invalid_json
run_case t04 "CLAUDE_AGENTS_STRIP_MODEL=0 で即降りる" case_t04_opt_out
run_case t05 "HOME 未設定でも非ゼロ終了しない" case_t05_home_unset
run_case t06 "settings.json が無ければ作らない" case_t06_settings_absent
run_case t07 "CLAUDE_CONFIG_DIR を尊重する" case_t07_claude_config_dir
run_case t08 "symlink（絶対）の実体に書き、リンクを壊さない" case_t08_symlink_absolute
run_case t09 "symlink（相対）の実体に書き、リンクを壊さない" case_t09_symlink_relative
run_case t10 "symlink（多段）の実体に書き、中間リンクも壊さない" case_t10_symlink_chain
run_case t11 "symlink ループでハングせず降りる" case_t11_symlink_loop
run_case t12 "壊れた symlink で何もしない" case_t12_symlink_broken
run_case t13 "読み取り専用ディレクトリで静かに降りる" case_t13_readonly_dir
run_case t14 "パーミッション 0600 を保つ" case_t14_mode_0600_preserved
run_case t15 "GNU stat スタブ（-c 経路）でも動く" case_t15_gnu_stat_stub
run_case t16 "CAS がロストアップデートを防ぐ" case_t16_cas_blocks_lost_update
run_case t17 "CAS の対照（競合が無ければ書く）" case_t17_cas_control
run_case t18 "他人のロック（トークン付き）を解放しない" case_t18_release_does_not_steal_foreign_lock
run_case t19 "他人のロック（空ディレクトリ）を消さない" case_t19_release_does_not_remove_empty_foreign_lock
run_case t20 "生きたロック中は静かに諦める" case_t20_live_lock_blocks_quietly
run_case t21 "stale ロックは奪って続行し、退避先も片付ける" case_t21_stale_lock_is_stolen
run_case t22 "並行 6 プロセス × 20 ラウンド" case_t22_concurrency
run_case t23 "mv 失敗を握り潰さず、しかし非ゼロ終了しない" case_t23_mv_failure_is_reported
run_case t24 "奪取されうる時刻を過ぎたら解放しない（解放の TOCTOU）" case_t24_release_refuses_after_stale_threshold
run_case t25 "stat 後に張り替わったロックを掴んだら奪取を諦める" case_t25_steal_detects_relinked_lock
run_case t26 "残った退避ディレクトリを回収する（実行中のものは残す）" case_t26_gc_collects_old_retired_lock
run_case t27 "取得が上界を超えたら成功として扱わない（取得の TOCTOU）" case_t27_try_lock_abandons_after_stale_threshold
run_case t28 "壊れた名前の退避ディレクトリを無視する" case_t28_gc_ignores_malformed_names

echo "install.sh"
run_case t30 "新規インストール" case_t30_install_fresh
run_case t31 "再実行が冪等で、登録済みは出し分ける" case_t31_install_idempotent
run_case t32 "CLAUDE_CONFIG_DIR を尊重する" case_t32_install_claude_config_dir
run_case t33 "空白を含むホームでも登録コマンドが動く" case_t33_install_quotes_hook_path
run_case t34 "クォート無しの旧登録を修正する" case_t34_install_upgrades_legacy_unquoted
run_case t34b "旧登録の差し替えが他のフック設定を巻き込まない" case_t34b_legacy_replacement_is_surgical
run_case t34c "クォート済みと旧登録の併存では旧登録を削除する" case_t34c_removes_legacy_when_current_exists
run_case t34d "メタ文字入りのホームでも登録コマンドが安全" case_t34d_quotes_metacharacter_path
run_case t35 "手動の ~ 登録は触らない" case_t35_install_keeps_manual_registration
run_case t35b "CLAUDE_CONFIG_DIR 環境の旧インストールを警告する（削除はしない）" case_t35b_warns_about_legacy_install
run_case t35c "旧インストールが無ければ警告しない" case_t35c_no_warning_without_legacy_install
run_case t35d "末尾スラッシュの CLAUDE_CONFIG_DIR で誤警告しない" case_t35d_no_false_warning_trailing_slash
run_case t35e "HOME が symlink でも誤警告しない" case_t35e_no_false_warning_symlinked_home
run_case t36 "settings.json が symlink（絶対）でも実体に書く" case_t36_install_settings_symlink
run_case t37 "settings.json が symlink（相対・多段）でも実体に書く" case_t37_install_settings_symlink_relative_chain
run_case t38 "symlink ループでも警告して続行する" case_t38_install_settings_symlink_loop
run_case t39 "壊れた symlink でも警告して続行する" case_t39_install_settings_symlink_broken
run_case t40 "実体ディレクトリが読み取り専用でも部分適用で死なない" case_t40_install_readonly_settings_dir
run_case t41 "古いエイリアスブロックを警告する" case_t41_alias_old_block_warns
run_case t42 "現行のエイリアスブロックでは警告しない" case_t42_alias_current_block_quiet
run_case t42b "permission-mode だけ欠けたブロックを出し分けて警告する" case_t42b_alias_missing_permission_mode_only
run_case t42c "ccd / ccw だけが古いブロックを出し分けて警告する" case_t42c_alias_ccd_ccw_stale
run_case t42d "ccw の旧い引数順を警告する" case_t42d_alias_ccw_wrong_order
run_case t42e "ccd から --agent claude が抜けたブロックを警告する" case_t42e_alias_ccd_missing_agent_claude
run_case t47 "permissions.defaultMode を設定しつつ兄弟キーを保つ" case_t47_default_mode_preserves_siblings
run_case t50 "permissions が非オブジェクトのとき生エラーを出さず専用警告で継続する" case_t50_non_object_permissions_survives
run_case t51 "CLAUDE_AGENTS_SET_DEFAULT_MODE=0 で defaultMode の書き込みをスキップする" case_t51_default_mode_opt_out

echo "README（アンインストール手順）"
run_case t43 "install → uninstall のラウンドトリップ" case_t43_readme_uninstall_roundtrip
run_case t44 "symlink ループでハングせず中断する" case_t44_readme_uninstall_symlink_loop
run_case t45 "jq 失敗時に隠しファイルを残さない" case_t45_readme_uninstall_broken_json
run_case t46 "CLAUDE_CONFIG_DIR 環境で symlink 削除まで追従する" case_t46_readme_uninstall_claude_config_dir
run_case t48 "uninstall は permissions の兄弟キーを残す" case_t48_uninstall_preserves_permission_siblings
run_case t49 "uninstall は空になった permissions を消す" case_t49_uninstall_drops_empty_permissions
run_case t52 "インストール前から空の permissions がある場合も uninstall で消す" case_t52_uninstall_drops_preexisting_empty_permissions

echo ""
echo "pass ${PASS_COUNT} / fail ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  printf '%s' "$FAILED_CASES"
  exit 1
fi
exit 0
