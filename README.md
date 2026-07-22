# claude-agents

Claude Code のモデル最適化アーキテクチャ。**Sonnet を入口にして、必要なタスクだけ Fable へ自動昇格させる 2 段階ルーター**と、Herdr 等のマルチペイン運用を前提としたオーケストレーターエージェントのセットです。

思想: **Fable は「作業量」ではなく「意思決定の重要度」で使う。** 正解が明確になった瞬間、実行は可能な限り下位モデルへ戻す。

## アーキテクチャ

```text
claude（全セッション共通の入口）
  │
  ▼
auto-router (Sonnet) ── タスクを 4 Tier に分類
  ├─ TIER 0  自分で直接処理（小修正・明確なバグ修正・質問）
  ├─ TIER 1  routine-worker (Sonnet) へ委譲（定型実装・テスト）
  ├─ TIER 2  deep-worker (Opus) へ委譲（難デバッグ・複雑実装）
  └─ TIER 3  frontier-orchestrator (Fable) へタスク全体を委譲
                │  ※ Edit/Write を持たない「司令塔」
                ├─ code-explorer (Sonnet)    探索
                ├─ routine-worker (Sonnet)   定型実装
                ├─ deep-worker (Opus)        難実装
                ├─ frontier-solver (Fable)   真の難問のみ
                ├─ test-runner (Sonnet)      検証
                └─ frontier-reviewer (Fable) 独立レビュー
```

### Tier 3 ゲート — 計画的 Fable と緊急 Fable の分離

Tier 3 に上がる前に、ルーターは不確実性の発生時点を判定します:

- **依頼時点から存在する不確実性**（新機能の仕様化・作り直し・アーキテクチャ依頼）→ 昇格せず停止し、**決定セッション**（`ccd` で起動する Fable メインの対話セッション）を推奨。サブエージェントは実行中にユーザーへ質問できないため、Tier 3 内で決まる設計はユーザー承認をバイパスしてしまう
- **実行中に発覚した不確実性**（前提崩れ・矛盾する証拠・原因不明・Opus の反復失敗）→ 即昇格
- **例外**: 本番インシデントは即昇格（対話的に仕様を固める時間がない）

## エージェント一覧

| エージェント | モデル | effort | 役割 |
|---|---|---|---|
| auto-router | Sonnet | high | 入口。Tier 分類とルーティング（メインセッション用） |
| orchestrator | Sonnet | high | マルチペイン運用の管理専任（実装しない、メインセッション用） |
| code-explorer | Sonnet | medium | 読み取り専用のコード探索・事実収集 |
| routine-worker | Sonnet | high | 定型実装・テスト・機械的リファクタ |
| test-runner | Sonnet | medium | テスト・型検査・lint の実行と要約 |
| deep-worker | Opus | high | 難デバッグ・複雑実装（方針確定済みで実行が難しいもの） |
| quality-reviewer | Opus | high | Tier 2 向け独立レビュー |
| frontier-orchestrator | Fable | high | Tier 3 司令塔。Edit/Write なし、判断と委譲に専念 |
| frontier-solver | Fable | high | 正解自体が不明な難問のみ（低頻度） |
| frontier-reviewer | Fable | high | 高リスク変更の独立レビュー（falsify 指向） |

## ペイン運用（Herdr 等のマルチペイン環境向け・任意）

| エイリアス | 展開先 | ペイン |
|---|---|---|
| `cco` | `claude --agent orchestrator` | **O 管理**: 指示文発行・PR 検証・マージ・追跡専任。起動時に状況同期が自動で走る |
| `ccd` | `claude --model fable` | **D 決定**: 仕様策定・アーキテクチャ設計・計画の敵対的検証。Fable をメインスレッドで使う唯一の入口。決定 1 件で使い捨て |
| `ccw` | `claude -w` | **W 実装**: セッション専用 worktree で実装〜PR 作成。`ccw <name>` で worktree に名前も付けられる |

シングルペイン運用でも auto-router 単体で完結します（ペイン運用は任意）。

## インストール

```bash
git clone https://github.com/Fumiya-Matsumoto/claude-agents.git
cd claude-agents
./install.sh
```

スクリプトがやること:

1. `agents/*.md` を `~/.claude/agents/` へ **symlink**（既存の実ファイルは `.bak` 退避）
2. `~/.claude/settings.json` に `"agent": "auto-router"` を設定（要 jq、バックアップ作成）
3. シェル rc に `cco` / `ccd` / `ccw` エイリアスを追加（マーカー付き・冪等）

symlink 方式なので、**更新は `git pull` だけ**で全マシンに反映されます。

### 前提

- Claude Code（Fable 5 が利用できるプラン）
- `jq`（settings.json の自動更新に使用。なければ手動追記の案内が出ます）
- bash / zsh

### 推奨スキル（[mattpocock/skills](https://github.com/mattpocock/skills)）

このアーキテクチャの一部は、Matt Pocock のワークフロースキル群が導入されていることを想定しています:

| スキル | 参照しているエージェント | 用途 |
|---|---|---|
| `grilling` | auto-router（Tier 3 ゲート）/ orchestrator | 計画・決定の敵対的検証 |
| `wayfinder` | auto-router（Tier 3 ゲート）/ orchestrator | 大きな目的の分解と道筋づくり |
| `to-spec` | auto-router（Tier 3 ゲート）/ orchestrator | 合意済みの決定を実装可能な仕様へ |
| `to-tickets` | orchestrator（D → W の橋渡し） | 仕様のチケット分解 |
| `tdd` | orchestrator（W ペイン指示文で指定） | テストファースト実装 |

導入（グローバル `~/.claude/skills/` へ）:

```bash
npx skills@latest add mattpocock/skills
```

**未導入でも壊れません。** ルーターとオーケストレーターは「スキルが導入済みならそれを使い、なければ同等の対話的な計画セッションで代替する」よう書かれています。D ペイン（`ccd`）は素の Fable 対話としてそのまま機能します。ただし決定フェーズの規律（敵対的検証・仕様化のフォーマット）はスキル側が担っているため、フル再現にはスキル導入を推奨します。

### 注意

- `settings.json` に `"model"` キーが残っていると auto-router の `model: sonnet` と競合しうるため、install.sh が警告します。削除推奨です（Fable が必要な場面は `ccd` / `--model fable` / `/model` で明示指定する設計）
- auto-router に `tools:` 許可リストを**意図的に付けていません**。付けると MCP ツール・Skill・Workflow がメインセッションから使えなくなるためです（許可リストは排他的）。ルーティング規律はプロンプトで担保しています

## プロジェクト特化

エージェントは**プロジェクト側の同名定義が優先**されます。プロジェクト固有の運用ルール（リポジトリ名、PR 規約、デプロイ確認、危険操作リスト）を焼き込みたい場合は、`agents/orchestrator.md` をプロジェクトの `.claude/agents/orchestrator.md` にコピーして「儀式」セクションを差し替えてください。

## アンインストール

```bash
# symlink 削除
find ~/.claude/agents -type l -lname "$(pwd)/agents/*" -delete
# settings.json から "agent" キーを削除
jq 'del(.agent)' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
# シェル rc から "# >>> claude-agents aliases >>>" 〜 "# <<< claude-agents aliases <<<" のブロックを削除
```

## License

MIT
