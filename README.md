# claude-agents

Claude Code の**判断の質でルーティングするエージェント構成**。入口は **Opus 5 のルーター**で、タスクが必要とする判断の質に応じて 4 Tier に振り分けます。加えて Herdr 等のマルチペイン運用を前提としたオーケストレーターエージェントのセットです。

最適化しているのはコストではなく**判断の質の配り方**です（安いモデルへ寄せることは目的ではありません）。

思想: **Fable は「作業量」ではなく「意思決定の重要度」で使う。** 正解が明確になった瞬間、実行は可能な限り下位モデルへ戻す。

## アーキテクチャ

**Tier は「必要な判断の質」で分けます。モデル帯は軸ではなく結果です。**

```text
claude（全セッション共通の入口）
  │
  ▼
auto-router (Opus) ── 必要な判断の質でタスクを 4 Tier に分類
  ├─ TIER 0  自分で直接処理（委譲の往復が仕事本体を上回るものだけ／狭く保つ）
  ├─ TIER 1  routine-worker (Sonnet) へ委譲（受け入れ基準を書き切れる＝正解が既知）
  ├─ TIER 2  deep-worker (Opus) へ委譲（正解の特定が要る／目的地は既知）
  └─ TIER 3  frontier-orchestrator (Fable) へタスク全体を委譲（目的地自体が未確定）
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

- **依頼時点から存在する不確実性**（新機能の仕様化・作り直し・アーキテクチャ依頼）→ 昇格せず停止し、**決定セッション**（`ccd` で起動する素の Fable 対話セッション）を推奨。サブエージェントは実行中にユーザーへ質問できないため、Tier 3 内で決まる設計はユーザー承認をバイパスしてしまう
- **実行中に発覚した不確実性**（前提崩れ・矛盾する証拠・原因不明・Tier 2 の反復失敗）→ 即昇格
- **例外**: 本番インシデントは即昇格（対話的に仕様を固める時間がない）

**このゲートの根拠は能力ではなく承認権限です。** ルーターが強力になっても判定基準は緩めません — 強くなって変わるのはバイパスの発生確率ではなく、バイパスしたまま最後までもっともらしく完走してしまう能力のほうだからです。

### レビューのルーティング — レビュアは実装者と別モデル

高リスク領域（DB スキーマ / マイグレーション・認証・認可・課金・セキュリティ・データ整合性・並行性・分散状態・不可逆な副作用・破壊的操作）はルータープロンプトで **1 本の列挙**として定義され、各 Tier がそれを参照します:

| Tier | 高リスク領域に触れたとき |
|---|---|
| TIER 0 | 自分で扱わない（委譲する） |
| TIER 1 | `quality-reviewer` (Opus) が独立レビュー ← 実装は Sonnet |
| TIER 2 | `frontier-reviewer` (Fable) が独立レビュー ← 実装は Opus |
| TIER 3 | かつ不確実性があるなら昇格 |

規則は「**レビュアは実装者と別モデルであればよい**」1 本に収束します。Tier 2 で Fable を当てるのは危険度が理由ではなく、`deep-worker` (Opus) の実装を `quality-reviewer` (Opus) が見る**相関ブラインドスポット**を消すためです（モデル多様性は effort をいくら上げても買えない）。

**通常の Tier 1 には独立レビューを課しません。** 代わりに完了条件を 2 つに固定しています — (1) 委譲時点で書き切った受け入れ基準と worker の報告の突き合わせ、(2) `test-runner` による独立検証。理由:

- 「基準から静かに外れる」型の失敗は、Tier 1 の入口条件（受け入れ基準を書き切れる）が既に大きく効いている
- 「自己申告が検証されていない」型は `test-runner` の**必須化**で閉じた。worker の `VERIFICATION:` は入力であって根拠ではない。`test-runner` は Sonnet 専用枠で走るため、委譲した実装成果すべて（Tier 1 / Tier 2）に広げても共通枠の消費はゼロ
- 残る「巻き添えで隣接を壊す」型だけが高リスク領域トリガーに値する。Tier 1 全件にレビューを課すと頻度がそのまま共通枠の消費になる
- ルーター自身はレビュアに数えない。周辺コードを読めば Tier 1 の委譲理由（実装コンテキストを主セッションに持ち込まない）が死に、かつ受け入れ基準の執筆者はフレーミングの相関を持つ

## エージェント一覧

| エージェント | モデル | effort | 役割 |
|---|---|---|---|
| auto-router | Opus | high | 入口。Tier 分類とルーティング（メインセッション用） |
| orchestrator | Opus | high | マルチペイン運用の管理専任（実装しない、メインセッション用） |
| code-explorer | Sonnet | high | 読み取り専用のコード探索・事実収集 |
| routine-worker | Sonnet | xhigh | 定型実装・テスト・機械的リファクタ |
| test-runner | Sonnet | high | テスト・型検査・lint の実行と要約 |
| deep-worker | Opus | high | 難デバッグ・複雑実装（方針確定済みで実行が難しいもの） |
| quality-reviewer | Opus | high | Tier 2 の独立レビュー ＋ 高リスクな Tier 1 |
| frontier-orchestrator | Fable | xhigh | Tier 3 司令塔。Edit/Write なし、判断と委譲に専念 |
| frontier-solver | Fable | xhigh | 正解自体が不明な難問のみ（低頻度） |
| frontier-reviewer | Fable | xhigh | 高リスク変更の独立レビュー（falsify 指向） |

モデル列は frontmatter の `model:` エイリアス（`sonnet` / `opus` / `fable` = それぞれ現行世代に解決される）。effort の配り方には 3 つの原則があります:

- **Sonnet 帯の effort 増は共通枠を圧迫しない** — Sonnet は専用の週次枠を持ち、使わなければ死蔵されるだけなので実質ゼロコストの品質購入
- **上げるならキャップされている側から** — Fable は共通枠の 50% でハードキャップされ構造的に暴走しない。キャップが無いのは Opus 帯のほうなので、`deep-worker` / `quality-reviewer` は `high` に据え置く
- **毎ターン走るメインセッション（`auto-router` / `orchestrator`）は意図的にデチューン**して `high`。遅延が全ターンに積算し、effort 変更は prompt cache を無効化するため

> メインセッションで起動する 2 体の effort 値は**意図値**です。実効値は起動時の既定値または `--effort` フラグに依存します（後述の「注意」を参照）。

## ペイン運用（Herdr 等のマルチペイン環境向け・任意）

| エイリアス | 展開先 | ペイン |
|---|---|---|
| `cco` | `claude --agent orchestrator` | **O 管理**: 指示文発行・PR 検証・マージ・追跡専任。`orchestrator` の frontmatter により Opus で走る。起動時に状況同期が自動で走る |
| `ccd` | `claude --model fable --agent claude --effort high` | **D 決定**: 仕様策定・計画・敵対的検証。**規模を問わず計画はここ**。Fable をメインスレッドで使う唯一の入口。決定 1 件で使い捨て |
| `ccw` | `claude -w` | **W 実装**: セッション専用 worktree で実装〜PR 作成。`ccw <name>` で worktree に名前も付けられる |

シングルペイン運用でも auto-router 単体で完結します（ペイン運用は任意）。

**`ccd` の `--agent claude` は必須です。** `settings.json` の `"agent": "auto-router"` は `--model` を渡しても効き続けるため、これが無いと D ペインは「Fable の上に auto-router を着せた」セッションになります。すると (1) Tier 3 ゲートが「停止して決定セッションを推奨せよ」と命じるのに自分がその決定セッションである、(2) 代わりに `frontier-orchestrator` へ委譲するとサブエージェントはユーザーに質問できないので、承認権限を根拠に守った境界が決定ペインの中でこそ破れる、という 2 つの自己矛盾が起きます。ビルトインの catch-all エージェント `claude` を明示して素の Fable 対話へ戻します。

**憲章は広く取り、深さは据え置き**（`--effort high`）。仕様化・計画・敵対的検証は規模を問わず D ペイン、難しいだけの実装・調査・デバッグは既定のメインセッションで足ります。「難しさで切る」と Opus 5 が Fable のピーク性能に肉薄している以上ほとんど D ペインを引かなくなるため、境界は難易度ではなく**仕事の種類**で引いています。

> 既にインストール済みの環境では、エイリアスはシェル rc に**書き込み済み**です（install.sh はマーカーで冪等なので上書きしません）。`ccd` の定義は rc 側を手で更新してください。

## インストール

```bash
git clone https://github.com/Fumiya-Matsumoto/claude-agents.git
cd claude-agents
./install.sh
```

スクリプトがやること:

1. `agents/*.md` を `~/.claude/agents/` へ **symlink**（既存の実ファイルは `.bak` 退避）
2. `skills/*/` を `~/.claude/skills/` へ **symlink**（agents-feedback スキル等）
3. `~/.claude/settings.json` に `"agent": "auto-router"` を設定（要 jq、バックアップ作成）。`"model"` / `"effortLevel"` が残っていれば削除を促す警告を出す（frontmatter と競合するため）
4. シェル rc に `cco` / `ccd` / `ccw` エイリアスを追加（マーカー付き・冪等）

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

- **model / effort の真実の源は `agents/*.md` の frontmatter に一本化しています。** `settings.json` の `"model"` はメインセッションで frontmatter の `model` に**勝ちます**（実測: 優先順位は `--model` フラグ > `settings.json` > frontmatter）。`"effortLevel"` は次項のとおり frontmatter 側が発火しないため、置けば実質そこが唯一の指定手段になります。いずれにせよ両方に書くと割当が 2 箇所に分裂します。`settings.json` は machine-local で配布されないので、必ずマシン間でズレます。install.sh が検出して削除を促します（`"agent": "auto-router"` は維持）。Fable が必要な場面は `ccd` / `--model fable` / `/model` で明示指定する設計です
- **frontmatter の `effort` はメインセッションでは発火しないようです**（transcript の `effort` 記録ベースの観測: `settings.json` から `effortLevel` を削除した状態で `auto-router` の frontmatter を `effort: low` にしても、記録される effort は `high` のまま）。frontmatter の `model` は発火します（同条件で `model: sonnet` にすると `claude-sonnet-5` になる）。メインセッションで起動する 2 体（`auto-router` / `orchestrator`）はどちらも `effort: high` を意図しており、これは現在の既定値と一致するため実害はありませんが、**メインセッションの effort をリポジトリ側から制御する手段は現状ありません**（サブエージェント経路では frontmatter の `effort` が効きます）。値を変えたい場合は `ccd` と同じく起動時の `--effort` フラグで渡してください
- auto-router に `tools:` 許可リストを**意図的に付けていません**。付けると MCP ツール・Skill・Workflow がメインセッションから使えなくなるためです（許可リストは排他的）。ルーティング規律はプロンプトで担保しています

## プロジェクト特化

エージェントは**プロジェクト側の同名定義が優先**されます。プロジェクト固有の運用ルール（リポジトリ名、PR 規約、デプロイ確認、危険操作リスト）を焼き込みたい場合は、`agents/orchestrator.md` をプロジェクトの `.claude/agents/orchestrator.md` にコピーして「儀式」セクションを差し替えてください。

GitHub にアップしていないプロジェクト（gh Issue / PR が使えない）では、追跡手段をプロジェクト固有のもの（タスク CLI、判断ログのディレクトリ等）に差し替えた auto-router / orchestrator オーバーライドを置いてください。

## 運用 — 障害時の退避とロールバック

新しい機構は作らず、**既に見えている状態（dirty tree / open Issue）にフックする**方針です。

### (A) Fable が使えないとき — 可用性の退避

Fable 5 には全面停止の実績があり（2026-06 に約 3 週間、輸出規制対応）、`frontier-*` 3 体と `ccd` が同時に死にます。**自動フォールバックは存在しません**（`--fallback-model` は `--print` 専用）。

**発動**: 起動に失敗 → 1 回再試行 → 回復せず、かつ `claude --model opus -p 'ok'` が通る → **即退避。公式告知は待ちません**（告知を見に行く人はいないので、実際の検知経路は必ず「作業中にエラーに遭遇する」）。probe は Fable 固有の停止と API 全体の不調を 10 秒で切り分けるためのものです。

**退避先は 3 体ではなく 4 つ**:

| 対象 | 退避後 |
|---|---|
| `agents/frontier-orchestrator.md` | `model: opus` / `effort: max` |
| `agents/frontier-solver.md` | `model: opus` / `effort: max` |
| `agents/frontier-reviewer.md` | `model: opus` / `effort: max` |
| `ccd`（エイリアスは rc 側にあり repo 管理外） | `claude --model opus --agent claude --effort high` を直打ち |

**commit しないのが要点です。** agents は symlink 配布なので作業ツリーを直接編集すれば即反映され、dirty な作業ツリーと `git status` がそのまま「今フォールバック中」の常時インジケータになります。main には意図した割当だけを残し、**復帰は `git checkout -- agents/` の 1 コマンド**（`claude --model fable -p 'ok'` が通ったら実行）。

**`effort: max` にする理由**: Fable は共通枠の 50% でハードキャップされているので、停止すればその消費が丸ごとゼロになり共通枠に余りが出ます。`max` の原資は停止で浮いた Fable 枠そのものです。

**埋まらないのは多様性だけです。** 停止中は実装もレビューも Opus になり、相関ブラインドスポットが開きます。これは effort では買い戻せないので、**停止中は高リスク作業のレビューを人間が持ちます**。

### (B) レート制限に日常的に当たるとき — 予算のロールバック

上限消費の倍率は非公開で「どちらが原因か測ってから決める」は原理的に実行できないため、**順序を先に決めてあります**:

1. **`ccd` の憲章を「不可逆性で切る」へ縮小**（幅から戻す）
2. **`frontier-*` を `effort: xhigh` → `high`**（深さを戻す）
3. それでも当たる → **マップを引き直す**

幅を先に戻すのは、`frontier-*` がルーターの Tier 3 ゲートに守られた需要駆動の消費で構造的な上限を持つのに対し、`ccd` のゲートは**人間の習慣だけ**で頻度に上限がないからです。また憲章の縮小は machine-local・即時・可逆で、frontmatter の変更は全マシンへの配布を伴います。「キャップされている側は最後に切る」— 安全だから買った品質を真っ先に捨てるのは論理の逆走です。

閾値は**主観**（「日常的に当たって煩わしい」）で構いません。ただし**一段降りたら `feedback` ラベルの Issue を open のまま立て、現在どの段にいるかを可視化**します。摩擦には気づいても**摩擦の不在には決して気づかない**ため、「当たらなくなったら戻す」は原理的に発火しないトリガーだからです。open な Issue は次の「FB蒸留」で自動的に俎上に載ります。

Fable の週次 50% キャップに**初めて**当たったときは、観測挙動（停止かサイレントフォールバックか）を `feedback` Issue に記録するだけにします。1 回当たるのは障害ではなく**ガードレールが設計どおり働いた状態**なので、ファイルは触りません。

### (C) 品質のドリフト

専用の監視機構は作りません。違和感は下記の `agents-feedback` ループにそのまま寄せます。

## フィードバックループ

各マシンでの運用で得た知見（誤ルーティング・プロンプトの穴・摩擦）は、このリポジトリの **GitHub Issue（label: `feedback`）** に集約し、エージェント定義の改訂へ還元します。

- **捕捉**: セッション中に「エージェントFB」と言うと `agents-feedback` スキル（install.sh が symlink 導入）が起動し、内容をサニタイズした上で `gh issue create --label feedback` で Issue 化される。gh が使えない環境では `feedback/` にファイルとして書き、後で Issue 化する
- **蒸留**: 「FB蒸留」で open な feedback Issue を 1 件ずつレビューし、採用分を `agents/*.md` / README に反映してクローズ
- **伝播**: agents / skills は symlink 配布なので、改訂後は各マシンで `git pull` するだけ
- **注意**: 公開リポジトリのため、Issue 本文にもプロジェクト固有情報（クライアント名・個人情報・金額等）を書かない。一般化した記述に変換する

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
