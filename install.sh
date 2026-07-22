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

# 3. settings.json に "agent": "auto-router" を設定
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.${STAMP}"
    tmp="$(mktemp)"
    jq '.agent = "auto-router"' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  else
    printf '{\n  "agent": "auto-router"\n}\n' > "$SETTINGS"
  fi
  echo 'settings.json: "agent": "auto-router" を設定'
  if jq -e 'has("model")' "$SETTINGS" | grep -q true; then
    echo '⚠ settings.json に "model" キーが残っています。auto-router の model: sonnet と競合しうるため削除を推奨します:'
    echo "    jq 'del(.model)' ${SETTINGS} > /tmp/s.json && mv /tmp/s.json ${SETTINGS}"
  fi
else
  echo '⚠ jq が見つかりません。settings.json に手動で "agent": "auto-router" を追加してください。'
fi

# 4. ペイン起動エイリアス
case "${SHELL##*/}" in
  zsh) RC="${HOME}/.zshrc" ;;
  *)   RC="${HOME}/.bashrc" ;;
esac
MARKER="# >>> claude-agents aliases >>>"
if ! grep -qF "$MARKER" "$RC" 2>/dev/null; then
  cat >> "$RC" << EOF

$MARKER
alias cco='claude --agent orchestrator'   # Orchestrator ペイン（管理専任）
alias ccd='claude --model fable'          # Decision ペイン（Fable で意思決定）
alias ccw='claude -w'                     # Worker ペイン（worktree 自動作成）
# <<< claude-agents aliases <<<
EOF
  echo "aliases: ${RC} に追加しました（source ${RC} で有効化）"
else
  echo "aliases: 設定済み（スキップ）"
fi

echo ""
echo "インストール完了。agents は symlink なので、更新はこのリポジトリで git pull するだけです。"
