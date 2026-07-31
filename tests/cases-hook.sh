#!/usr/bin/env bash
# hooks/claude-agents-strip-model.sh のケース。tests/run.sh から source される。
# 単体では動かない（assert 群・run_case は run.sh 側にある）。

# mtime を小数まで取る。ロックや一時ファイルの「作って消した」痕跡は親
# ディレクトリの mtime に残るので、それで副作用の有無を判定する。
# 秒までの解像度しか無い環境では取りこぼす（偽陽性ではなく偽陰性側に倒れる）。
precise_mtime() {
  "$REAL_STAT" -c '%.9Y' "$1" 2>/dev/null || "$REAL_STAT" -f '%Fm' "$1" 2>/dev/null
}

# ---------------------------------------------------------------- 収束

case_t01_converge() {
  local s="${HOME}/.claude/settings.json" fp1
  write_settings "$s" "$DEFAULT_SETTINGS"
  run_hook
  assert_hook_ok "t01 1回目"
  assert_eq "t01 model が剥がれる" "$(jq -r 'has("model")' "$s")" "false"
  assert_eq "t01 effortLevel が正規化される" "$(jq -r '.effortLevel' "$s")" "xhigh"
  assert_eq "t01 無関係のキーは保持される" "$(jq -r '.canary' "$s")" "keep-me"
  assert_eq "t01 パーミッションが保たれる" "$(file_mode "$s")" "644"
  assert_eq "t01 stderr は空" "$HOOK_ERR" ""
  fp1="$(fingerprint "$s")"
  run_hook
  assert_hook_ok "t01 2回目"
  assert_unchanged "t01 2回目は書き込まない（fast path）" "$s" "$fp1"
  assert_clean "t01" "${HOME}/.claude" "${HOME}/.claude"
}

# ---------------------------------------------------------------- 適用範囲外

# "agent" キーが無い settings.json（このリポジトリ未導入の環境）は触らない。
# ロックも一時ファイルも作らないこと ―― PR #34 で fast path の判定を値ベースに
# した際、ここが毎ターン「ロック取得 → 一時ファイル作成 → 後段ガードで却下」を
# 永久に繰り返す退行として混入した。
case_t02_no_agent_key() {
  local s="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json" before
  write_settings "$s" '{"model":"fable","effortLevel":"low"}'
  cp "$s" "$ref"
  before="$(precise_mtime "${HOME}/.claude")"
  run_hook
  assert_hook_ok "t02"
  assert_same_bytes "t02 settings.json は不変" "$s" "$ref"
  assert_eq "t02 設定ディレクトリに副作用が無い" "$(precise_mtime "${HOME}/.claude")" "$before"
  assert_clean "t02" "${HOME}/.claude" "${HOME}/.claude"
}

case_t03_invalid_json() {
  local s="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json" before
  write_settings "$s" '{"agent": "auto-router", "model": ,,, broken'
  cp "$s" "$ref"
  before="$(precise_mtime "${HOME}/.claude")"
  run_hook
  assert_hook_ok "t03"
  assert_same_bytes "t03 壊れた JSON はバイト単位で不変" "$s" "$ref"
  assert_eq "t03 設定ディレクトリに副作用が無い" "$(precise_mtime "${HOME}/.claude")" "$before"
  assert_clean "t03" "${HOME}/.claude" "${HOME}/.claude"
}

case_t04_opt_out() {
  local s="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json" before
  write_settings "$s" "$DEFAULT_SETTINGS"
  cp "$s" "$ref"
  before="$(precise_mtime "${HOME}/.claude")"
  export CLAUDE_AGENTS_STRIP_MODEL=0
  run_hook
  unset CLAUDE_AGENTS_STRIP_MODEL
  assert_hook_ok "t04"
  assert_same_bytes "t04 opt-out 時は不変" "$s" "$ref"
  assert_eq "t04 設定ディレクトリに副作用が無い" "$(precise_mtime "${HOME}/.claude")" "$before"
}

case_t05_home_unset() {
  local status
  write_settings "${HOME}/.claude/settings.json" "$DEFAULT_SETTINGS"
  env -u HOME bash "$HOOK" >"${SANDBOX}/out" 2>"${SANDBOX}/err"
  status=$?
  assert_eq "t05 HOME 未設定でも終了 0" "$status" "0"
  assert_eq "t05 HOME 未設定で stderr を出さない" "$(cat "${SANDBOX}/err")" ""
}

case_t06_settings_absent() {
  mkdir -p "${HOME}/.claude"
  run_hook
  assert_hook_ok "t06"
  assert_file_absent "t06 settings.json を作らない" "${HOME}/.claude/settings.json"
  assert_clean "t06" "${HOME}/.claude" "${HOME}/.claude"
}

# ---------------------------------------------------------------- CLAUDE_CONFIG_DIR

case_t07_claude_config_dir() {
  local custom="${SANDBOX}/xdg-config/claude" s ref
  s="${custom}/settings.json"
  ref="${HOME}/.claude/settings.json"
  write_settings "$s" "$DEFAULT_SETTINGS"
  write_settings "$ref" "$DEFAULT_SETTINGS"
  cp "$ref" "${SANDBOX}/ref.json"
  export CLAUDE_CONFIG_DIR="$custom"
  run_hook
  unset CLAUDE_CONFIG_DIR
  assert_hook_ok "t07"
  assert_eq "t07 CLAUDE_CONFIG_DIR 側が正規化される" "$(jq -r 'has("model")' "$s")" "false"
  assert_same_bytes "t07 ~/.claude 側は触らない" "$ref" "${SANDBOX}/ref.json"
  assert_clean "t07" "$custom" "$custom"
}

# ---------------------------------------------------------------- symlink

# 共通: settings.json が symlink のとき、リンクではなく実体を書き換えること
# （mv はリンクを辿らないので、素朴に書くと dotfiles 管理の symlink が切れる）
assert_symlink_case() { # label link real
  assert_hook_ok "$1"
  [ -L "$2" ] || fail "$1: symlink が実ファイルに置き換わった"
  assert_eq "$1 実体が正規化される" "$(jq -r 'has("model")' "$3")" "false"
  assert_eq "$1 実体の effortLevel" "$(jq -r '.effortLevel' "$3")" "xhigh"
  assert_eq "$1 実体のパーミッション保持" "$(file_mode "$3")" "644"
}

case_t08_symlink_absolute() {
  local real="${SANDBOX}/dotfiles/settings.json" link="${HOME}/.claude/settings.json"
  write_settings "$real" "$DEFAULT_SETTINGS"
  mkdir -p "${HOME}/.claude"
  ln -s "$real" "$link"
  run_hook
  assert_symlink_case "t08 絶対パス symlink" "$link" "$real"
  assert_clean "t08" "${HOME}/.claude" "${SANDBOX}/dotfiles"
}

case_t09_symlink_relative() {
  local real="${HOME}/.claude/dotfiles/settings-real.json" link="${HOME}/.claude/settings.json"
  write_settings "$real" "$DEFAULT_SETTINGS"
  ln -s "dotfiles/settings-real.json" "$link"
  run_hook
  assert_symlink_case "t09 相対パス symlink" "$link" "$real"
  assert_clean "t09" "${HOME}/.claude" "${HOME}/.claude/dotfiles"
}

case_t10_symlink_chain() {
  local real="${SANDBOX}/dotfiles/settings.json" link="${HOME}/.claude/settings.json"
  write_settings "$real" "$DEFAULT_SETTINGS"
  mkdir -p "${HOME}/.claude" "${SANDBOX}/hop"
  ln -s "$real" "${SANDBOX}/hop/second"
  ln -s "../hop/second" "${SANDBOX}/dotfiles/first"
  ln -s "${SANDBOX}/dotfiles/first" "$link"
  run_hook
  assert_symlink_case "t10 多段 symlink" "$link" "$real"
  [ -L "${SANDBOX}/hop/second" ] || fail "t10: 中間の symlink が置き換わった"
  assert_clean "t10" "${HOME}/.claude" "${SANDBOX}/dotfiles"
}

# symlink ループ: ハングせず終了 0 で降りること
case_t11_symlink_loop() {
  local link="${HOME}/.claude/settings.json"
  mkdir -p "${HOME}/.claude"
  ln -s "${HOME}/.claude/loop-b" "$link"
  ln -s "$link" "${HOME}/.claude/loop-b"
  run_hook
  assert_hook_ok "t11 symlink ループ"
  assert_eq "t11 stderr は空" "$HOOK_ERR" ""
  [ -L "$link" ] || fail "t11: symlink が置き換わった"
  assert_clean "t11" "${HOME}/.claude" "${HOME}/.claude"
}

case_t12_symlink_broken() {
  local link="${HOME}/.claude/settings.json"
  mkdir -p "${HOME}/.claude"
  ln -s "${SANDBOX}/does-not-exist.json" "$link"
  run_hook
  assert_hook_ok "t12 壊れた symlink"
  assert_eq "t12 stderr は空" "$HOOK_ERR" ""
  assert_file_absent "t12 リンク先を作らない" "${SANDBOX}/does-not-exist.json"
  [ -L "$link" ] || fail "t12: symlink が置き換わった"
  assert_clean "t12" "${HOME}/.claude" "${HOME}/.claude"
}

# ---------------------------------------------------------------- 権限

case_t13_readonly_dir() {
  local s="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json"
  write_settings "$s" "$DEFAULT_SETTINGS"
  cp "$s" "$ref"
  chmod 0555 "${HOME}/.claude"
  run_hook
  chmod 0755 "${HOME}/.claude"
  assert_hook_ok "t13 読み取り専用ディレクトリ"
  assert_same_bytes "t13 settings.json は不変" "$s" "$ref"
  assert_eq "t13 stderr は空（ロックが取れず静かに降りる）" "$HOOK_ERR" ""
  assert_clean "t13" "${HOME}/.claude" "${HOME}/.claude"
}

case_t14_mode_0600_preserved() {
  local s="${HOME}/.claude/settings.json"
  write_settings "$s" "$DEFAULT_SETTINGS"
  chmod 0600 "$s"
  run_hook
  assert_hook_ok "t14"
  assert_eq "t14 0600 が保たれる" "$(file_mode "$s")" "600"
  assert_eq "t14 正規化されている" "$(jq -r 'has("model")' "$s")" "false"
}

# ---------------------------------------------------------------- stat の経路

# BSD 環境でも GNU 経路（stat -c）を通す。`stat -f` を先に試す実装だと GNU では
# --file-system と解釈されて壊れるため、順序が逆になっていないことをここで
# 機械的に検出する（過去にこの順序がマージブロッカーとして混入した）。
case_t15_gnu_stat_stub() {
  local s="${HOME}/.claude/settings.json" stubs
  stubs="$(stub_dir)"
  cat > "${stubs}/stat" <<EOF
#!/usr/bin/env bash
# GNU coreutils の stat を模したスタブ。-c だけを解し、-f は GNU と同じく
# --file-system 扱いで失敗する。
# 実処理は本物の stat へ委譲するが、その本物が GNU か BSD かで渡し方を変える。
# 常に BSD 書式へ変換して -f で渡すと、GNU ホスト（Linux）では本物の stat が
# -f を --file-system と解釈してこのスタブ自体が壊れる ―― GNU 経路を検証する
# ためのテストが GNU 環境でだけ落ちる、という逆立ちになる。
echo "\$1" >> "${SANDBOX}/stat.log"
fmt=""
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -c) fmt="\$2"; shift 2 ;;
    --format=*) fmt="\${1#--format=}"; shift ;;
    -f) echo "stat: cannot read file system information" >&2; exit 1 ;;
    *) args[\${#args[@]}]="\$1"; shift ;;
  esac
done
[ -n "\$fmt" ] || { echo "stat: no format" >&2; exit 1; }
if [ "${REAL_STAT_IS_GNU}" = "yes" ]; then
  exec "$REAL_STAT" -c "\$fmt" "\${args[@]}"
fi
fmt="\${fmt//%Y/%m}"
fmt="\${fmt//%s/%z}"
fmt="\${fmt//%a/%Lp}"
exec "$REAL_STAT" -f "\$fmt" "\${args[@]}"
EOF
  chmod +x "${stubs}/stat"
  export PATH="${stubs}:${PATH}"
  write_settings "$s" "$DEFAULT_SETTINGS"
  chmod 0640 "$s"
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t15 GNU stat スタブ"
  assert_eq "t15 スタブが実際に使われた" "$([ -s "${SANDBOX}/stat.log" ] && echo yes || echo no)" "yes"
  assert_contains "t15 GNU 書式で呼ばれている" "$(cat "${SANDBOX}/stat.log")" "-c"
  assert_not_contains "t15 BSD 書式へフォールバックしていない" "$(cat "${SANDBOX}/stat.log")" "-f"
  assert_eq "t15 正規化されている" "$(jq -r 'has("model")' "$s")" "false"
  assert_eq "t15 パーミッション保持（GNU 経路）" "$(file_mode "$s")" "640"
  assert_clean "t15" "${HOME}/.claude" "${HOME}/.claude"
}

# ---------------------------------------------------------------- CAS

# 読み出し〜mv の窓で Claude Code 本体が settings.json を書いた状況を、jq の
# スタブから決定的に再現する（sleep でタイミングを狙わない）。CAS が無いと
# 本体の書き込みが "model" 以外のキーごと巻き戻る。
install_racing_jq_stub() { # 追加で書き込む jq プログラム
  local stubs settings
  stubs="$(stub_dir)"
  settings="${1}"
  cat > "${stubs}/jq" <<EOF
#!/usr/bin/env bash
race=""
for a in "\$@"; do
  case "\$a" in *"del(.model)"*) race=1 ;; esac
done
"$REAL_JQ" "\$@"
st=\$?
if [ -n "\$race" ] && [ -z "\${STRIP_MODEL_TEST_NO_RACE:-}" ]; then
  # 本体（/config 等）の書き込みを模す。一時ファイル + rename で置き換える
  t="\$(mktemp "\$(dirname "$settings")/.settings.json.other.XXXXXX")"
  "$REAL_JQ" '.racedKey = "written-by-claude-code"' "$settings" > "\$t" && mv "\$t" "$settings"
fi
exit \$st
EOF
  chmod +x "${stubs}/jq"
  export PATH="${stubs}:${PATH}"
}

case_t16_cas_blocks_lost_update() {
  local s="${HOME}/.claude/settings.json"
  write_settings "$s" "$DEFAULT_SETTINGS"
  install_racing_jq_stub "$s"
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t16"
  assert_eq "t16 本体の書き込みが残る（ロストアップデートしない）" \
    "$(jq -r '.racedKey' "$s")" "written-by-claude-code"
  assert_eq "t16 巻き戻していない（model はそのまま残る）" "$(jq -r '.model' "$s")" "fable"
  assert_eq "t16 巻き戻していない（effortLevel もそのまま）" "$(jq -r '.effortLevel' "$s")" "high"
  assert_clean "t16" "${HOME}/.claude" "${HOME}/.claude"
  # 次のターンで再試行され収束すること（諦めっぱなしにならない）
  run_hook
  assert_eq "t16 次のターンで収束する" "$(jq -r 'has("model")' "$s")" "false"
  assert_eq "t16 本体のキーは保たれたまま" "$(jq -r '.racedKey' "$s")" "written-by-claude-code"
}

# 対照実験: 同じスタブでも競合が起きなければ普通に書き込む
# （t16 がスタブの副作用で常に通ってしまう偽陽性を排除する）
case_t17_cas_control() {
  local s="${HOME}/.claude/settings.json"
  write_settings "$s" "$DEFAULT_SETTINGS"
  install_racing_jq_stub "$s"
  export STRIP_MODEL_TEST_NO_RACE=1
  run_hook
  unset STRIP_MODEL_TEST_NO_RACE
  export PATH="$ORIG_PATH"
  assert_hook_ok "t17"
  assert_eq "t17 競合が無ければ書き込む" "$(jq -r 'has("model")' "$s")" "false"
  assert_eq "t17 effortLevel が正規化される" "$(jq -r '.effortLevel' "$s")" "xhigh"
}

# ---------------------------------------------------------------- ロック

# 変換 jq の実行中に「他人が stale と判断して奪取した」状況を作る。
# EXIT trap が無条件 rmdir だと、他人の生きたロックを解放してしまう。
install_lock_stealing_jq_stub() { # lock_dir foreign_token(空文字ならトークン無しの空ロック)
  local stubs lock token
  stubs="$(stub_dir)"
  lock="$1"
  token="$2"
  cat > "${stubs}/jq" <<EOF
#!/usr/bin/env bash
race=""
for a in "\$@"; do
  case "\$a" in *"del(.model)"*) race=1 ;; esac
done
"$REAL_JQ" "\$@"
st=\$?
if [ -n "\$race" ] && [ ! -e "${SANDBOX}/stolen" ]; then
  : > "${SANDBOX}/stolen"
  rm -f "${lock}/token"
  rmdir "${lock}"
  mkdir "${lock}"
  if [ -n "${token}" ]; then printf '%s\n' "${token}" > "${lock}/token"; fi
fi
exit \$st
EOF
  chmod +x "${stubs}/jq"
  export PATH="${stubs}:${PATH}"
}

case_t18_release_does_not_steal_foreign_lock() {
  local s="${HOME}/.claude/settings.json" lock="${HOME}/.claude/.strip-model.lock"
  write_settings "$s" "$DEFAULT_SETTINGS"
  install_lock_stealing_jq_stub "$lock" "foreign-token"
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t18"
  assert_file_exists "t18 他人のロックを解放しない" "$lock"
  assert_eq "t18 他人のトークンが残っている" "$(cat "${lock}/token" 2>/dev/null)" "foreign-token"
  rm -f "${lock}/token"; rmdir "$lock" 2>/dev/null
}

# トークン更新前に落ちた等で「空のロックディレクトリ」が他人のものとして
# 存在するケース。自分のトークンと一致しないので解放してはいけない。
case_t19_release_does_not_remove_empty_foreign_lock() {
  local s="${HOME}/.claude/settings.json" lock="${HOME}/.claude/.strip-model.lock"
  write_settings "$s" "$DEFAULT_SETTINGS"
  install_lock_stealing_jq_stub "$lock" ""
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t19"
  assert_file_exists "t19 他人の空ロックを消さない" "$lock"
  rmdir "$lock" 2>/dev/null
}

case_t20_live_lock_blocks_quietly() {
  local s="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json" lock="${HOME}/.claude/.strip-model.lock"
  write_settings "$s" "$DEFAULT_SETTINGS"
  cp "$s" "$ref"
  mkdir "$lock"
  printf 'someone-else\n' > "${lock}/token"
  run_hook
  assert_hook_ok "t20"
  assert_same_bytes "t20 ロック中は書き込まない" "$s" "$ref"
  assert_eq "t20 stderr は空" "$HOOK_ERR" ""
  assert_eq "t20 他人のロックは無傷" "$(cat "${lock}/token")" "someone-else"
  rm -f "${lock}/token"; rmdir "$lock"
}

case_t21_stale_lock_is_stolen() {
  local s="${HOME}/.claude/settings.json" lock="${HOME}/.claude/.strip-model.lock"
  write_settings "$s" "$DEFAULT_SETTINGS"
  mkdir "$lock"
  printf 'dead-process\n' > "${lock}/token"
  touch -t 202001010000 "$lock"
  run_hook
  assert_hook_ok "t21"
  assert_eq "t21 stale ロックを奪って処理する" "$(jq -r 'has("model")' "$s")" "false"
  assert_clean "t21" "${HOME}/.claude" "${HOME}/.claude"
}

# ---------------------------------------------------------------- 並行

# 6 プロセス × 20 ラウンド。各ラウンドで「本体が /model を書いた」相当の
# 外部書き込みを挟むので、ロックと CAS の両方に競合がかかる。
case_t22_concurrency() {
  local s="${HOME}/.claude/settings.json" i statuses
  write_settings "$s" "$DEFAULT_SETTINGS"
  : > "${SANDBOX}/nonzero"
  for i in 1 2 3 4 5 6; do
    (
      r=0
      while [ "$r" -lt 20 ]; do
        r=$((r + 1))
        t="$(mktemp "${HOME}/.claude/.settings.json.other.XXXXXX")"
        # 外部の書き手（Claude Code 本体相当）もパーミッションを保つ。
        # mktemp は 0600 なので、ここで戻さないとテスト側の書き込みが
        # 0644 -> 0600 のラチェットを起こし、フックの検証にならない
        chmod 0644 "$t"
        if jq '.model = "fable"' "$s" > "$t" 2>/dev/null; then mv "$t" "$s"; else rm -f "$t"; fi
        bash "$HOOK" 2>>"${SANDBOX}/concurrent.stderr"
        st=$?
        [ "$st" -eq 0 ] || printf '%s\n' "worker ${i} round ${r}: exit ${st}" >> "${SANDBOX}/nonzero"
      done
    ) &
  done
  wait
  statuses="$(cat "${SANDBOX}/nonzero")"
  assert_eq "t22 全実行が終了 0" "$statuses" ""
  assert_eq "t22 stderr を出さない" "$(cat "${SANDBOX}/concurrent.stderr" 2>/dev/null)" ""
  assert_eq "t22 有効な JSON のまま" "$(jq -r 'type' "$s" 2>/dev/null)" "object"
  assert_eq "t22 agent キーが失われていない" "$(jq -r '.agent' "$s")" "auto-router"
  assert_eq "t22 無関係のキーが失われていない" "$(jq -r '.canary' "$s")" "keep-me"
  assert_eq "t22 パーミッションが保たれる" "$(file_mode "$s")" "644"
  assert_clean "t22" "${HOME}/.claude" "${HOME}/.claude"
  run_hook
  assert_eq "t22 最後に収束する" "$(jq -r 'has("model")' "$s")" "false"
  assert_eq "t22 最後に effortLevel が正規化される" "$(jq -r '.effortLevel' "$s")" "xhigh"
}

# ---------------------------------------------------------------- mv 失敗

# mv が失敗しても非ゼロ終了せず、しかし黙って握り潰さない（stderr に 1 行）。
# 実体ディレクトリだけを読み取り専用にして再現する（ロックと一時ファイルは
# CLAUDE_CONFIG_DIR 側の書ける場所に作られる）。
case_t23_mv_failure_is_reported() {
  local s="${HOME}/.claude/settings.json" ref="${SANDBOX}/ref.json" stubs real_mv
  write_settings "$s" "$DEFAULT_SETTINGS"
  cp "$s" "$ref"
  # 実体を差し替えると CAS 側で弾かれてしまい mv まで到達しないので、
  # mv そのものを失敗させる（権限・別デバイス等の代表）。
  stubs="$(stub_dir)"
  real_mv="$(command -v mv)"
  cat > "${stubs}/mv" <<EOF
#!/usr/bin/env bash
# 最後の引数（mv の宛先）が settings.json なら失敗する。宛先はフックが
# pwd -P で正規化した物理パス（macOS では /private/var/... 側）なので、
# パス全体ではなく末尾で判定する
last="\${!#}"
case "\$last" in
  */settings.json)
    echo "mv: Operation not permitted" >&2
    exit 1
    ;;
esac
exec "$real_mv" "\$@"
EOF
  chmod +x "${stubs}/mv"
  export PATH="${stubs}:${PATH}"
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t23 mv 失敗でも終了 0"
  assert_contains "t23 失敗を stderr に出す" "$HOOK_ERR" "claude-agents-strip-model"
  assert_same_bytes "t23 settings.json は元のまま" "$s" "$ref"
  assert_clean "t23" "${HOME}/.claude" "${HOME}/.claude"
}

# ---------------------------------------------------------------- 解放の TOCTOU

# 保持時間が STALE_SECONDS を超えていたら、トークンが一致していても解放しない。
# 照合と rm/rmdir はアトミックではないので、照合の直後に他人が stale 奪取して
# 作り直したロックを消しうる（レビュー指摘 F1）。奪取は 60 秒より古いロックに
# しか起きないので、「保持時間が短いこと」を確認できれば奪取されていないことが
# 言える。
#
# 60 秒待たずに検証するため date をスタブ化する。変換 jq（＝ロック取得より後、
# 解放より前）がマーカーを置き、それ以降の `date +%s` だけが 120 秒進んだ値を
# 返す。呼び出し回数に依存しないので、フック側の date 呼び出し箇所が増減しても
# 壊れない。
case_t24_release_refuses_after_stale_threshold() {
  local s="${HOME}/.claude/settings.json" lock="${HOME}/.claude/.strip-model.lock"
  local stubs base real_date
  write_settings "$s" "$DEFAULT_SETTINGS"
  stubs="$(stub_dir)"
  base="$(date +%s)"
  real_date="$(command -v date)"
  cat > "${stubs}/date" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "+%s" ] && [ -e "${SANDBOX}/timewarp" ]; then
  echo "$((base + 120))"
  exit 0
fi
exec "$real_date" "\$@"
EOF
  chmod +x "${stubs}/date"
  cat > "${stubs}/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *"del(.model)"*) : > "${SANDBOX}/timewarp" ;; esac
done
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "${stubs}/jq"
  export PATH="${stubs}:${PATH}"
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t24"
  assert_eq "t24 書き込み自体は行われる" "$(jq -r 'has("model")' "$s")" "false"
  assert_file_exists "t24 奪取されうる時刻を過ぎたら解放しない" "$lock"
  assert_ne "t24 トークンは残したまま" "$(cat "${lock}/token" 2>/dev/null)" ""
  rm -f "${lock}/token"; rmdir "$lock" 2>/dev/null
}

# stat で stale と判定してから mv するまでの間に $LOCK が別のディレクトリへ
# 張り替わった場合、それは「生きたロック」でありうる（レビュー指摘 F2）。
# mv 後に mtime と inode の組を確認して、掴んだものが違えば奪取を諦め、しかも
# 相手の中身は壊さない。
case_t25_steal_detects_relinked_lock() {
  local s="${HOME}/.claude/settings.json" lock="${HOME}/.claude/.strip-model.lock"
  local ref="${SANDBOX}/ref.json" stubs retired
  write_settings "$s" "$DEFAULT_SETTINGS"
  cp "$s" "$ref"
  mkdir "$lock"
  printf 'victim\n' > "${lock}/token"
  touch -t 202001010000 "$lock"
  stubs="$(stub_dir)"
  cat > "${stubs}/stat" <<EOF
#!/usr/bin/env bash
# 本物の stat に委譲し、ロックディレクトリの stat に成功した最初の 1 回だけ、
# その直後に「別プロセスが奪取して生きたロックを作り直した」状況へ差し替える
out="\$("$REAL_STAT" "\$@" 2>/dev/null)"
st=\$?
last="\${!#}"
if [ \$st -eq 0 ] && [ ! -e "${SANDBOX}/relinked" ]; then
  case "\$last" in
    *.strip-model.lock)
      : > "${SANDBOX}/relinked"
      rm -f "${lock}/token"
      rmdir "${lock}"
      mkdir "${lock}"
      printf 'live-lock\n' > "${lock}/token"
      ;;
  esac
fi
[ \$st -eq 0 ] && printf '%s\n' "\$out"
exit \$st
EOF
  chmod +x "${stubs}/stat"
  export PATH="${stubs}:${PATH}"
  run_hook
  export PATH="$ORIG_PATH"
  assert_hook_ok "t25"
  assert_same_bytes "t25 ロックが取れないので書き込まない" "$s" "$ref"
  retired="$(ls -d "${HOME}/.claude"/.strip-model.lock.stale.* 2>/dev/null | head -1)"
  if [ -z "$retired" ]; then
    fail "t25: 退避ディレクトリが無い（mv 自体が行われていない）"
  else
    assert_eq "t25 掴んだ生きたロックの中身を壊さない" "$(cat "${retired}/token" 2>/dev/null)" "live-lock"
    rm -f "${retired}/token"; rmdir "$retired"
  fi
  rm -f "${lock}/token" 2>/dev/null; rmdir "$lock" 2>/dev/null
}

# 奪取の途中で SIGKILL された等で残った退避ディレクトリを回収する（F4）。
# 年齢は名前に埋め込まれた epoch で判断するので、実行中の奪取（epoch が新しい）
# は巻き込まない。
case_t26_gc_collects_old_retired_lock() {
  local s="${HOME}/.claude/settings.json" old new
  write_settings "$s" "$DEFAULT_SETTINGS"
  old="${HOME}/.claude/.strip-model.lock.stale.99999-$(( $(date +%s) - 600 ))-424242"
  new="${HOME}/.claude/.strip-model.lock.stale.99998-$(date +%s)-131313"
  mkdir "$old" "$new"
  printf 'dead\n' > "${old}/token"
  printf 'inflight\n' > "${new}/token"
  run_hook
  assert_hook_ok "t26"
  assert_file_absent "t26 古い退避ディレクトリを回収する" "$old"
  assert_file_exists "t26 実行中の奪取の退避先は消さない" "$new"
  assert_eq "t26 実行中の奪取のトークンも消さない" "$(cat "${new}/token" 2>/dev/null)" "inflight"
  assert_eq "t26 回収しても本来の処理は続く" "$(jq -r 'has("model")' "$s")" "false"
  rm -f "${new}/token"; rmdir "$new"
}
