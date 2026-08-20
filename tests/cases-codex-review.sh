#!/usr/bin/env bash
# bin/codex-review の SKIP 経路（セッション 1 回上限 / 枠ガード）に対する
# 回帰テスト。tests/run.sh から source される（単体では動かない）。
#
# 実際の codex CLI・codex-ratelimits は一切呼ばない（ネットワーク不要・
# 枠を消費しない）。codex CLI は PATH 先頭に置くスタブに、codex-ratelimits
# はサンドボックスへコピーした codex-review の隣に置くスタブに、それぞれ
# 完全に差し替える。codex-review は helper を `$(dirname -- "$0")` で探す
# （PATH 経由ではない）ため、リポジトリ本体の bin/codex-review を直接実行
# すると隣にスタブを置けない — 毎ケースでサンドボックスへコピーしてから使う。

CODEX_REVIEW_SRC="${REPO_DIR}/bin/codex-review"

STDIN_FIXTURE=$'## この変更が満たすべき受け入れ基準（原文引用）\nダミー\n\n## 観測されている事実\nなし'

# codex-review をサンドボックスへコピーする。CR_BIN_DIR / CR_BIN を設定する。
setup_codex_review() {
  CR_BIN_DIR="${SANDBOX}/crbin"
  mkdir -p "$CR_BIN_DIR"
  cp "$CODEX_REVIEW_SRC" "${CR_BIN_DIR}/codex-review"
  chmod +x "${CR_BIN_DIR}/codex-review"
  CR_BIN="${CR_BIN_DIR}/codex-review"
}

# codex-ratelimits のスタブを codex-review の隣に置く（python3 ソース全文を
# 渡す）。呼ばなければ「ヘルパが見つからない」経路になる。
write_ratelimits_stub() { # python source
  printf '%s\n' "$1" > "${CR_BIN_DIR}/codex-ratelimits"
  chmod +x "${CR_BIN_DIR}/codex-ratelimits"
}

# codex CLI のスタブを PATH の先頭に置く。呼ばれたら invocation_log に 1 行
# 記録する（「起動されていない」ことを機械的に確認するため）。outcome が
# success なら -o 引数の先へダミー本文を書いて exit 0、fail なら何も書かず
# exit 1（`codex exec review` 失敗を模す）。
write_codex_cli_stub() { # invocation_log outcome(success|fail)
  local stubs invocation_log="$1" outcome="$2"
  stubs="$(stub_dir)"
  cat > "${stubs}/codex" <<EOF
#!/usr/bin/env bash
echo "invoked \$*" >> "${invocation_log}"
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out="\$a"; fi
  prev="\$a"
done
if [ "${outcome}" = "success" ]; then
  [ -n "\$out" ] && echo "stub review body: no findings" > "\$out"
  exit 0
else
  exit 1
fi
EOF
  chmod +x "${stubs}/codex"
  export PATH="${stubs}:${PATH}"
}

run_codex_review() { # target stdin_content
  local target="$1" input="${2-}"
  printf '%s' "$input" | "$CR_BIN" "$target" >"${SANDBOX}/cr.stdout" 2>"${SANDBOX}/cr.stderr"
  CR_STATUS=$?
  CR_OUT="$(cat "${SANDBOX}/cr.stdout")"
  CR_ERR="$(cat "${SANDBOX}/cr.stderr")"
  return 0
}

# ---------------------------------------------------------------- B: セッション 1 回上限

case_t60_session_marker_blocks() {
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" invlog="${SANDBOX}/codex.invocations" marker_dir
  setup_codex_review
  write_codex_cli_stub "$invlog" success
  marker_dir="${HOME}/.claude/cache/codex-review-fired"
  mkdir -p "$marker_dir"
  : > "${marker_dir}/${sid}"

  export CLAUDE_CODE_SESSION_ID="$sid"
  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"

  assert_eq "t60 終了ステータス" "$CR_STATUS" "125"
  assert_contains "t60 stderr にセッション上限の理由" "$CR_ERR" "既に系列外レビューが走りました"
  [ -e "$invlog" ] && fail "t60: codex CLI が起動されている（走ってはいけない）"
}

case_t63_marker_created_only_on_success() {
  local sid="ffffffff-1111-2222-3333-444444444444" invlog="${SANDBOX}/codex.invocations" marker
  setup_codex_review
  write_codex_cli_stub "$invlog" success
  marker="${HOME}/.claude/cache/codex-review-fired/${sid}"

  export CLAUDE_CODE_SESSION_ID="$sid"
  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  assert_eq "t63 1 回目は成立する" "$CR_STATUS" "0"
  assert_file_exists "t63 成立後にマーカーができる" "$marker"

  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"
  assert_eq "t63 同一セッションの 2 回目は 125" "$CR_STATUS" "125"
}

case_t63b_marker_not_created_on_failure() {
  local sid="99999999-8888-7777-6666-555555555555" invlog="${SANDBOX}/codex.invocations" marker
  setup_codex_review
  write_codex_cli_stub "$invlog" fail
  marker="${HOME}/.claude/cache/codex-review-fired/${sid}"

  export CLAUDE_CODE_SESSION_ID="$sid"
  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"

  assert_ne "t63b codex 失敗で終了する" "$CR_STATUS" "0"
  assert_file_absent "t63b 失敗時はマーカーを作らない" "$marker"
}

# ---------------------------------------------------------------- A: 枠ガード

case_t61_quota_guard_blocks() {
  local invlog="${SANDBOX}/codex.invocations"
  setup_codex_review
  write_codex_cli_stub "$invlog" success
  write_ratelimits_stub '#!/usr/bin/env python3
import sys, json
if len(sys.argv) > 1 and sys.argv[1] == "ratelimits":
    print(json.dumps({"account/rateLimits/read": {
        "rateLimitReachedType": None,
        "primary": {"usedPercent": 92},
    }}))
    sys.exit(0)
sys.exit(2)
'

  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"

  assert_eq "t61 終了ステータス" "$CR_STATUS" "126"
  assert_contains "t61 stderr に枠の状態" "$CR_ERR" "primary.usedPercent=92"
  [ -e "$invlog" ] && fail "t61: codex exec review が起動されている（走ってはいけない）"
}

case_t62a_ratelimits_failure_passes_through() {
  local invlog="${SANDBOX}/codex.invocations"
  setup_codex_review
  write_codex_cli_stub "$invlog" success
  write_ratelimits_stub '#!/usr/bin/env python3
import sys
sys.exit(1)
'

  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"

  assert_eq "t62a 終了ステータス" "$CR_STATUS" "0"
  assert_contains "t62a レビュー本文が返る" "$CR_OUT" "stub review body"
  assert_not_contains "t62a 枠ガードのメッセージは出ない" "$CR_ERR" "枠ガード"
  [ -e "$invlog" ] || fail "t62a: codex exec review が起動されていない（素通りできていない）"
}

case_t62b_ratelimits_malformed_json_passes_through() {
  local invlog="${SANDBOX}/codex.invocations"
  setup_codex_review
  write_codex_cli_stub "$invlog" success
  write_ratelimits_stub '#!/usr/bin/env python3
print("not json")
'

  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"

  assert_eq "t62b 終了ステータス" "$CR_STATUS" "0"
  assert_contains "t62b レビュー本文が返る" "$CR_OUT" "stub review body"
  [ -e "$invlog" ] || fail "t62b: codex exec review が起動されていない（素通りできていない）"
}

case_t62c_ratelimits_helper_missing_passes_through() {
  local invlog="${SANDBOX}/codex.invocations"
  setup_codex_review
  write_codex_cli_stub "$invlog" success
  # write_ratelimits_stub を呼ばない＝隣に codex-ratelimits が無い状態

  run_codex_review "main...HEAD" "$STDIN_FIXTURE"
  export PATH="$ORIG_PATH"

  assert_eq "t62c 終了ステータス" "$CR_STATUS" "0"
  assert_contains "t62c レビュー本文が返る" "$CR_OUT" "stub review body"
  [ -e "$invlog" ] || fail "t62c: codex exec review が起動されていない（素通りできていない）"
}
