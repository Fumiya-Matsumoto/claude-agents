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

## Codex レーン（系列外レビュー）の指摘 — 型の反復だけを起票

`codex-review`（系列外レビュー）と `frontier-reviewer` の指摘は、完了報告に
採用・却下を問わず全件が原文で列挙される（`agents/orchestrator.md` 参照）。
この完了報告群を材料にするときの基準は「有用だったか」ではなく **同じ型の
指摘が反復したか** の 1 本にする:

- **同じ型の指摘が複数回の完了報告にまたがって繰り返し出ている**（採用・
  却下いずれでも）→ 上記の捕捉手順で Issue を起票する
- 単発の指摘（1 回だけ出た）は、それがどれほど的確でも・どれほど的外れでも
  上げない

理由: このスキルの目的はエージェント定義の改訂であり、「Codex や
frontier-reviewer が良い指摘をした」という事実は単体では `.md` を変える
理由にならない。一方、**同じ型の有用な指摘が反復する**なら Claude 側
レビュアの盲点が体系的だという証拠になり、reviewer の `.md` に観点を足す
根拠になる。同じ型の却下が反復する場合も同様に、レビュアが同じ誤検知を
繰り返している体系的な問題として扱う（却下側の基準は既に同じ軸で定まって
おり、ここはそれを有用側にも揃えたもの）。有用/却下で判定基準を分けると
軸が 2 本になって運用が重くなるだけで、得られるものが無い。

## 蒸留（「FB蒸留」「feedback消化」と言われたら）

1. `gh issue list --repo Fumiya-Matsumoto/claude-agents --label feedback --state open`
2. 1 件ずつ提示し、採用 / 見送り / 保留を松本さんに確認する
3. 採用分を `agents/*.md` / `README.md` に反映し、ブランチを切って
   コミット（`fb: <summary> (closes #N)`）→ push → PR。マージは松本さん
4. マージ後、各マシンは `git pull` するだけで反映される

## 定期確認（「FB蒸留」のたびに）— Codex 側の値の陳腐化

専用の監視経路は作らない。README「運用 — 障害時の退避とロールバック」の
(D) 節が定める既定方針（値の陳腐化は専用機構を作らず、(B) の再調整と
この agents-feedback ループに合流させる）にそのまま乗せる。新しい機構では
なく、「FB蒸留」の手順に次を 1 つ足すだけ:

1. `~/.claude/bin/codex-ratelimits models` を叩く（`codex app-server` の
   `model/list` を消費ゼロで読む。python3 が要る。無ければこの確認は
   スキップしてよい — 専用の監視経路ではないので無理に代替経路を探さない）
2. 出力の `data[].id` に、`bin/codex-review` が固定している `gpt-5.6-sol`
   がまだ存在するか確認する。**消えていれば引退**
3. `gpt-5.6-sol` の要素の `supportedReasoningEfforts` に、`bin/codex-review`
   が固定している `xhigh` が含まれるか確認する。**消えていれば同様に引退**
4. `supportedReasoningEfforts` の**上位に、既知の集合
   （`low` / `medium` / `high` / `xhigh` / `max` / `ultra`。2026-07-31 時点）
   を超える新しい effort が増えていないか**確認する

2・3 のいずれかで値が引退していた場合、または 4 で新しい上位 effort が
増えていた場合は、上記の捕捉手順で Issue を起票する（`bin/codex-review` の
`-m` / `model_reasoning_effort` を書き換える提案を添える。実際に値を
変えるかどうかの判断は README (D) を読んで行う — `max` / `ultra` が既に
増えている現時点では、発火頻度を守るため `xhigh` に据え置く判断が済んでいる）。

## 書き方の指針

- 修正はエージェントプロンプトの**一般則**として書く。特定プロジェクト固有の
  運用はそのプロジェクトの `.claude/agents/` 同名オーバーライド側に書く（例: life）
- 1 Issue = 1 事象。まとめて書かない（蒸留時に裁きやすくする）
