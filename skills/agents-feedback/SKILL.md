---
name: agents-feedback
description: claude-agents（auto-router / orchestrator / worker 群）の運用で得た知見・違和感・改善案を GitHub Issue に記録し、エージェント定義の改訂へ還元する。トリガー: 「エージェントFB」「ルーターFB」「エージェント改善」「ルーティングおかしい」「FB蒸留」「feedback消化」等。
---

# agents-feedback — 運用知見の還元ループ

claude-agents は symlink 配布のグローバル資産。運用中に見つけた誤ルーティング・
プロンプトの穴・摩擦を GitHub Issue に集約し、定義改訂 → `git pull` で
全マシンへ還元する。

## リポジトリ

- GitHub: `Fumiya-Matsumoto/claude-agents`（**公開リポジトリ**）
- ローカル clone は symlink から逆引きする:

```bash
REPO_DIR="$(dirname "$(dirname "$(readlink "$HOME/.claude/agents/auto-router.md")")")"
```

## 捕捉（「エージェントFB」と言われたら）

1. 事象を整理する: 対象エージェント / 状況 / 期待と実際 / 改善案。
   直近の会話から自明なら質問せず埋め、不明点だけ確認する
2. **裏取り**: ドキュメントと実環境のズレを報告する時は、まず上流
   （参照先リポジトリ・配布元）の現状を確認し、**ローカル環境が古いだけ**
   ではないか切り分けてから Issue 化する。ローカル起因ならローカルを直して終わり
   （例: 参照スキル名の不一致 → 実は導入済みスキルが改名前の古い版だった）
3. **サニタイズ（必須・公開リポジトリ）**: クライアント名・個人名・金額・
   案件やプライベート固有の詳細を書かない。事象を一般化した記述に変換する
   （例: 「クライアントXの広告日次スクリプト」→「定型のバッチスクリプト」）
4. Issue を作成する（本文に発生マシンの hostname を添える）:

```bash
gh issue create --repo Fumiya-Matsumoto/claude-agents \
  --title "<agent名 or repo>: <一行サマリ>" \
  --label feedback \
  --body "$(cat <<'EOF'
## 状況
（サニタイズ済みの一般化した記述）

## 期待と実際
- 期待:
- 実際:

## 提案
（どのファイルのどの記述をどう変えるか）

---
machine: <hostname>
EOF
)"
```

5. 修正が自明・低リスク（typo・明らかな記述ズレ）なら、その場で
   `$REPO_DIR/agents/*.md` を直接編集してよい（symlink なので即反映）。
   コミット・push は必ず松本さんに確認し、適用内容を Issue にコメントで残す
6. gh が使えない環境では `$REPO_DIR/feedback/YYYY-MM-DD-<slug>.md` に
   同内容を書き、オンラインになったら Issue 化して削除する

## 蒸留（「FB蒸留」「feedback消化」と言われたら）

1. `gh issue list --repo Fumiya-Matsumoto/claude-agents --label feedback --state open`
2. 1 件ずつ提示し、採用 / 見送り / 保留を松本さんに確認する
3. 採用分を `agents/*.md` / `README.md` に反映し、ブランチを切って
   コミット（`fb: <summary> (closes #N)`）→ push → PR。マージは松本さん
4. マージ後、各マシンは `git pull` するだけで反映される

## 書き方の指針

- 修正はエージェントプロンプトの**一般則**として書く。特定プロジェクト固有の
  運用はそのプロジェクトの `.claude/agents/` 同名オーバーライド側に書く（例: life）
- 1 Issue = 1 事象。まとめて書かない（蒸留時に裁きやすくする）
