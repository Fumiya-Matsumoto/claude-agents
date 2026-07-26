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

# 4. settings.json に "agent": "auto-router" を設定
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.${STAMP}"
    tmp="$(mktemp)"
    jq '.agent = "auto-router"' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  else
    printf '{\n  "agent": "auto-router"\n}\n' > "$SETTINGS"
  fi
  echo 'settings.json: "agent": "auto-router" を設定'
  if jq -e 'has("model") or has("effortLevel")' "$SETTINGS" | grep -q true; then
    echo '⚠ settings.json に "model" / "effortLevel" キーが残っています。'
    echo '  これらはメインセッションで agents/*.md の frontmatter に勝つため、model / effort の'
    echo '  割当が settings.json（machine-local・配布されない）と frontmatter の 2 箇所に分裂します。'
    echo '  このリポジトリは frontmatter を唯一の真実の源とする設計なので、削除を推奨します:'
    echo "    jq 'del(.model, .effortLevel)' ${SETTINGS} > /tmp/s.json && mv /tmp/s.json ${SETTINGS}"
  fi
else
  echo '⚠ jq が見つかりません。settings.json に手動で "agent": "auto-router" を追加してください。'
fi

# 5. ペイン起動エイリアス
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

# 6. 系列外レビュー（任意）の前提を検出。未導入でも中断しない
if command -v codex >/dev/null 2>&1; then
  echo "codex: 検出しました（系列外レビューが有効になります）"
else
  echo 'ℹ codex CLI が見つかりません。系列外レビューはスキップされます（構成は壊れません）。'
  echo '  導入すると、独立レビューが走る場面で系列外の第 2 レビュアが並行で走ります。'
fi

echo ""
echo "インストール完了。agents は symlink なので、更新はこのリポジトリで git pull するだけです。"
