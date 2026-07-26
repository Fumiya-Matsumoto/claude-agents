#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
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

# 5. settings.json に "agent": "auto-router" を設定 ＋ Stop フックを冪等に登録
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.${STAMP}"
    # 一時ファイルは settings.json と同じディレクトリに作る（$TMPDIR だと
    # クロスデバイスになり得て mv のアトミック性が失われるため）
    tmp="$(mktemp "${CLAUDE_DIR}/.settings.json.install.XXXXXX")"
    if jq '.agent = "auto-router"' "$SETTINGS" > "$tmp"; then
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

  # Stop フックへ claude-agents-strip-model.sh を追記登録する。既存の Stop
  # エントリ（例: notify-stop.sh）や SessionStart フックは絶対に壊さない。
  # コマンド文字列に claude-agents-strip-model.sh を含むかどうかで既存判定
  # する（完全一致だと ~ 表記の手動登録と絶対パス登録が二重になるため）。
  # 登録するコマンド自体は絶対パスで固定する（~ はフック実行シェルに
  # よっては展開されないため）。`objects` で要素の型を絞り、Stop がオブ
  # ジェクト形式だったり hooks 配列に文字列等が混入していても落ちないよう
  # にする。
  HOOK_CMD="bash ${HOOKS_DIR}/claude-agents-strip-model.sh"
  tmp="$(mktemp "${CLAUDE_DIR}/.settings.json.install.XXXXXX")"
  if jq --arg needle "claude-agents-strip-model.sh" --arg cmd "$HOOK_CMD" '
    .hooks //= {} |
    .hooks.Stop //= [] |
    (
      if ([.hooks.Stop[]? | objects | .hooks[]? | objects | .command? // empty] | any(contains($needle))) then
        .
      else
        .hooks.Stop += [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
      end
    )
  ' "$SETTINGS" > "$tmp"; then
    mv "$tmp" "$SETTINGS"
    echo 'settings.json: Stop フックに claude-agents-strip-model.sh を登録（冪等）'
  else
    rm -f "$tmp"
    echo '⚠ Stop フックの登録に失敗しました（jq エラー）。手動登録が必要です（claude-agents-strip-model.sh を参照）。'
  fi

  if jq -e 'has("model") or has("effortLevel")' "$SETTINGS" 2>/dev/null | grep -q true; then
    echo '⚠ settings.json に "model" / "effortLevel" キーが残っています。'
    echo '  これらはメインセッションで agents/*.md の frontmatter に勝つため、model / effort の'
    echo '  割当が settings.json（machine-local・配布されない）と frontmatter の 2 箇所に分裂します。'
    echo '  このリポジトリは frontmatter を唯一の真実の源とする設計です。上で登録した Stop フックが'
    echo '  次のターンの応答完了時に自動で剥がすので、通常は放置して構いません。すぐに消したい場合は:'
    echo "    jq 'del(.model, .effortLevel)' ${SETTINGS} > /tmp/s.json && mv /tmp/s.json ${SETTINGS}"
  fi
else
  echo '⚠ jq が見つかりません。settings.json に手動で "agent": "auto-router" を追加してください。'
  echo '  また Stop フックも手動登録が必要です（claude-agents-strip-model.sh を参照）。'
fi

# 6. ペイン起動エイリアス
case "${SHELL##*/}" in
  zsh) RC="${HOME}/.zshrc" ;;
  *)   RC="${HOME}/.bashrc" ;;
esac
MARKER="# >>> claude-agents aliases >>>"
if ! grep -qF "$MARKER" "$RC" 2>/dev/null; then
  cat >> "$RC" << EOF

$MARKER
alias cco='claude --agent orchestrator'                              # Orchestrator ペイン（管理専任）
alias ccd='claude --model fable --agent claude --effort high'        # Decision ペイン（素の Fable で意思決定）
alias ccw='claude -w'                                                # Worker ペイン（worktree 自動作成）
# <<< claude-agents aliases <<<
EOF
  echo "aliases: ${RC} に追加しました（source ${RC} で有効化）"
else
  echo "aliases: 設定済み（スキップ）"
fi

# 7. 系列外レビュー（任意）の前提を検出。未導入でも中断しない
if command -v codex >/dev/null 2>&1; then
  echo "codex: 検出しました（系列外レビューが有効になります）"
else
  echo 'ℹ codex CLI が見つかりません。系列外レビューはスキップされます（構成は壊れません）。'
  echo '  導入すると、独立レビューが走る場面で系列外の第 2 レビュアが並行で走ります。'
fi

echo ""
echo "インストール完了。agents は symlink なので、更新はこのリポジトリで git pull するだけです。"
