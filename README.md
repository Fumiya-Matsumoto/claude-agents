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

  ※ 独立レビューが走るときは必ず、系列外の codex exec review (OpenAI Codex CLI)
    を並行で同時起動する（起動点は auto-router の COMPLETION 節 /
    frontier-orchestrator / orchestrator の 3 箇所。未導入でも壊れません）
```

### Tier 3 ゲート — 計画的 Fable と緊急 Fable の分離

Tier 3 に上がる前に、ルーターは不確実性の発生時点を判定します:

- **依頼時点から存在する不確実性**（新機能の仕様化・作り直し・アーキテクチャ依頼）→ 昇格せず停止し、**決定セッション**（`ccd` で起動する素の Fable 対話セッション）を推奨。サブエージェントは実行中にユーザーへ質問できないため、Tier 3 内で決まる設計はユーザー承認をバイパスしてしまう
- **実行中に発覚した不確実性**（前提崩れ・矛盾する証拠・原因不明・Tier 2 の反復失敗）→ 即昇格
- **例外**: 本番インシデントは即昇格（対話的に仕様を固める時間がない）

**このゲートの根拠は能力ではなく承認権限です。** ルーターが強力になっても判定基準は緩めません — 強くなって変わるのはバイパスの発生確率ではなく、バイパスしたまま最後までもっともらしく完走してしまう能力のほうだからです。

### レビューのルーティング — レビュアは実装者と別モデル

高リスク領域（DB スキーマ / マイグレーション・認証・認可・課金・セキュリティ・データ整合性・並行性・分散状態・不可逆な副作用・破壊的操作）はルータープロンプトで **1 本の列挙**として定義され、各 Tier がそれを参照します:

| Tier | 高リスク領域に触れたとき | 系列外レビュー |
|---|---|---|
| TIER 0 | 自分で扱わない（委譲する） | — |
| TIER 1 | `quality-reviewer` (Opus) が独立レビュー ← 実装は Sonnet | 並行で `codex exec review` |
| TIER 2 | `frontier-reviewer` (Fable) が独立レビュー ← 実装は Opus | 並行で `codex exec review` |
| TIER 3 | かつ不確実性があるなら昇格 | 並行で `codex exec review`（Tier 3 は全件） |

規則は「**レビュアは実装者と別モデルであればよい**」1 本に収束します。Tier 2 で Fable を当てるのは危険度が理由ではなく、`deep-worker` (Opus) の実装を `quality-reviewer` (Opus) が見る**相関ブラインドスポット**を消すためです（モデル多様性は effort をいくら上げても買えない）。

**通常の Tier 1 には独立レビューを課しません。** 代わりに完了条件を 2 つに固定しています — (1) 委譲時点で書き切った受け入れ基準と worker の報告の突き合わせ、(2) `test-runner` による独立検証。理由:

- 「基準から静かに外れる」型の失敗は、Tier 1 の入口条件（受け入れ基準を書き切れる）が既に大きく効いている
- 「自己申告が検証されていない」型は `test-runner` の**必須化**で閉じた。worker の `VERIFICATION:` は入力であって根拠ではない。適用を Tier 1 に限定せず委譲した実装成果すべて（Tier 1 / Tier 2）に広げたのは、Tier が「必要な判断の質」の軸であって検証の要否の軸ではないから ＋ Tier 1 だけ必須と書くと Tier 2 のほうが緩く読めるため（`quality-reviewer` は diff を読むのであってテスト実行を保証しない）
- 残る「巻き添えで隣接を壊す」型だけが高リスク領域トリガーに値する。Tier 1 全件にレビューを課すと頻度がそのまま共通枠の消費になる
- ルーター自身はレビュアに数えない。周辺コードを読めば Tier 1 の委譲理由（実装コンテキストを主セッションに持ち込まない）が死に、かつ受け入れ基準の執筆者はフレーミングの相関を持つ

### 系列外レビュー（Codex）— 相関除去のための第 2 レビュア

「レビュアは実装者と別モデル」で買っているのは能力差ではなく**相関の除去**です。ただし Opus も Fable も Anthropic 系列内にあり、系列そのものに由来する盲点は残ります。**OpenAI Codex CLI は系列外にある唯一の駒**なので、この構成が構造的に買えなかったものを供給できます。

> **発火条件は新設しません。既存の独立レビューが走るときは、必ず Codex も走ります。**

新しいトリガーも新しい設定キーも作らず、既存レビュアの発火条件に**寄生**します（カバー範囲は (Tier 1 ∧ 高リスク) ∨ (非自明な Tier 2) ∨ Tier 3 ∨ O ペインの高リスク PR ＝ `frontier-reviewer` / `quality-reviewer` が走るすべて）。ルーターに増える判断はゼロで、**通常の Tier 1 は対象外**のまま。起動点は寄生先の数だけあり、**3 箇所**です:

| 起動点 | 寄生先 |
|---|---|
| `auto-router` の `COMPLETION` 節 | `quality-reviewer` / `frontier-reviewer`（Tier 1・Tier 2） |
| `frontier-orchestrator` の `QUALITY GATE` | `frontier-reviewer`（Tier 3 全件。Fable が委譲し Fable がレビューする、最も相関の濃い場所） |
| `orchestrator`（O ペイン）の共通ルール | `frontier-reviewer`（高リスク PR の検証） |

- **足すのであって置き換えません。** `quality-reviewer` / `frontier-reviewer` は発火条件・担当・model/effort すべて無変更。理由は 3 つ — 検出能力の証拠がまだ薄い（同一差分でも指摘の優先度がぶれる実測がある）、Codex は MCP 経由で GitHub Issue を読むので**完全独立ではない**、`codex exec review` は diff レビュー専用ハーネスで `frontier-reviewer` の falsify 型レビューとは射程が違う
- **「Claude 枠の節約」は根拠にしていません**（測定で反証済み。消費の 76% は主セッションで、レビュアは低頻度）。買っているのは相関除去だけです
- **Claude レビュアと並行（同時起動）**。「Claude レビュアの指摘を Codex に見せない」がプロンプト規律ではなく**構造**で担保されます（レビュー時点で指摘がまだ存在しない）。同期実行の待ち時間もレビュア待ちに吸収されます
- **往復はゼロ**。指摘を採用して直せば新しい完了サイクルになり、寄生規則で自然にもう 1 回だけ発火します。却下の記録も残しません（同じ差分を二度見ないため。同じ**型**の却下が繰り返されるなら、それは抑制対象ではなく規則側を直すシグナルなので `agents-feedback` に上げます）
- **裁き手はルーター。ただし採用・却下とも全件を原文のまま完了報告に列挙**し、各件に `採用 / 却下（理由）` を付けます。「却下する動機を持つ側が裁く」問題を、裁定権の移転ではなく**可視性**で殺す設計です（人間は上訴審、通常時の摩擦はゼロ）
- **失敗してもブロックしません**（枠切れ・CLI 未導入・実行失敗）。ただし黙って落ちず、完了報告に「系列外レビューは走らなかった（理由）」を必ず書きます

#### 渡すもの / 伏せるもの — 境界は「出典」で引く

| 出典 | 扱い |
|---|---|
| ユーザの原文の指示、元 Issue の受け入れ基準、再現手順、**失敗しているテストの生出力**、エラーログ | **渡す（原文引用・要約禁止）** |
| ルーターの分類理由・Tier、原因の仮説、設計判断とその理由、worker の `VERIFICATION:`、**「全テスト通過」**、Claude レビュアの指摘、「レビュー済み」という事実 | **伏せる** |

**受け入れ基準は渡します。** 伏せると「実装が要件を満たしていない」という最も価値の高い指摘が原理的に出なくなるためです（元 Issue の基準やユーザの原文は人間由来なので、系列内の閉路にはならない）。`test-runner` の扱いは**非対称**で、赤は生出力のまま渡し、緑は伏せます（「通っている」は探索を狭める最も強い暗示で、独立検証は既に済んでいるので情報として無価値）。**要約した瞬間に Claude のフレーミングが混ざる**ので要約は禁止です。

**「伏せる」を担保するのは人間の規律でもプロンプト規律でもなく CLI フラグです。** 起動は `bin/codex-review`（install.sh が `~/.claude/bin/` へ symlink）1 本に集約し、フラグを毎回散文から書き起こさない形にしています:

```bash
codex exec review - \
  --ignore-user-config \                # skills / memories / machine-local な model・effort を断つ
  --ephemeral \                         # セッションを残さない
  --disable apps \                      # MCP の裏口を閉じる（実測で確定）
  -c sandbox_mode=read-only \
  -c approval_policy=never \
  -m gpt-5.6-sol \
  -c model_reasoning_effort="xhigh" \
  -o <出力先>
```

`--disable apps` が要る理由は実測です — **MCP プラグインはサンドボックスを素通りします**。付けない場合、read-only 実行でも Codex は GitHub の Issue を指示なしに読み込み（＝ Claude の推論成果物に接続し）、さらに**書き込み系ツール（Issue の更新・作成）まで生きています**。`--ignore-user-config` は skills / memories / `AGENTS.md` と machine-local な model・effort を断ちます。観点はすべてプロンプト本文に載るので、リポジトリ側に `AGENTS.md` 等を新設する必要はありません。

**残存リスク（フラグでは閉じません）**:

- `read-only` サンドボックスは**ディスク全体の読み取りを許します**。スクリプトのプロンプトは「リポジトリ外のファイルは読まないでください」と指示していますが、これは規律であって担保ではありません。機微なファイルを含むマシンでは、この点を承知のうえで使ってください
- `--ignore-user-config` が読まないのは **`$CODEX_HOME/config.toml`（＝ユーザー設定）だけ**です。**レビュー対象のリポジトリが `.codex/config.toml` を持ち、そこに `mcp_servers` を定義している場合、その MCP は残る可能性があります**（未実測。このリポジトリ自身は `.codex/` を持たないので現時点の露出はありません）。プロジェクト側に MCP 定義を持つリポジトリでレビューを回す前に、実機で確認してください

**未導入でも壊れません。** `codex` が無ければスクリプトは exit 127 で即座に降り、Claude レビュアだけが走ります（完了報告にその旨が明記されます）。

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

`quality-reviewer` / `frontier-reviewer` による独立レビューが走る場面では、加えて**系列外の `codex exec review`（OpenAI Codex CLI・任意）が並行で走ります**。これは Claude のサブエージェントではないので frontmatter を持たず、この表には載りません（前節「系列外レビュー（Codex）」を参照）。

モデル列は frontmatter の `model:` エイリアス（`sonnet` / `opus` / `fable` = それぞれ現行世代に解決される）。effort の配り方には 3 つの原則があります:

- **どの帯の消費も共通枠を食う** — Max の週次上限は「全モデル共通枠」と「Fable 枠」の 2 本（`/usage` の実測）。**Sonnet 専用の枠は存在しない**ので、Sonnet 帯の effort 増もコストはゼロではない。上げた分は共通枠から出ている
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
3. `bin/*` を `~/.claude/bin/` へ **symlink**（系列外レビューの起動スクリプト `codex-review`）
4. `hooks/*` を `~/.claude/hooks/` へ **symlink**（`settings.json` から `"model"` / `"effortLevel"` を剥がす `claude-agents-strip-model.sh`）
5. `~/.claude/settings.json` に `"agent": "auto-router"` を設定（要 jq、バックアップ作成）。加えて `Stop` フックへ `claude-agents-strip-model.sh` を追記登録する（既存の `Stop` / `SessionStart` エントリは保持したまま追記。コマンド文字列で既存判定するため再実行しても重複登録されない）。`"model"` / `"effortLevel"` が残っていれば、次のターンでフックが自動的に消す旨と手動削除コマンドを表示する
6. シェル rc に `cco` / `ccd` / `ccw` エイリアスを追加（マーカー付き・冪等）
7. `codex` CLI の有無を検出して表示（未導入でも中断しません。系列外レビューがスキップされるだけです）

symlink 方式なので、**更新は `git pull` だけ**で全マシンに反映されます。ただし**配布物が増えたときだけは例外**で、`git pull` しても新しい symlink は張られません。系列外レビューの `bin/` は新しく増えた配布物なので、**既に導入済みのマシンでは `./install.sh` を 1 度だけ再実行してください**（冪等です）。再実行しない場合、`codex` が導入済みでもスクリプトが見つからず系列外レビューは走りません。

### 前提

- Claude Code（Fable 5 が利用できるプラン）
- `jq`（settings.json の自動更新に使用。なければ手動追記の案内が出ます）
- bash / zsh
- **任意**: OpenAI Codex CLI（`codex`。系列外レビューに使用）。**未導入でも壊れません** — 系列外レビューがスキップされ、その旨が完了報告に明記されるだけです

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

- **model / effort の真実の源は `agents/*.md` の frontmatter に一本化しています。** `settings.json` の `"model"` はメインセッションで frontmatter の `model` に**勝ちます**（実測: 優先順位は `--model` フラグ > `settings.json` > frontmatter）。`"effortLevel"` は次項のとおり frontmatter 側が発火しないため、置けば実質そこが唯一の指定手段になります。いずれにせよ両方に書くと割当が 2 箇所に分裂します。`settings.json` は machine-local で配布されないので、必ずマシン間でズレます。Fable が必要な場面は `ccd` / `--model fable` / `/model` で明示指定する設計です。**`/model` はもともとそのセッション限りの切替という意味論のコマンドですが、実行すると `settings.json` に書き込まれて恒久化してしまいます。** install.sh は `hooks/claude-agents-strip-model.sh` を `Stop` フックとして登録し、セッションが応答を終えるたびに `"model"` / `"effortLevel"` を自動で剥がします（毎ターン走りますが、キーが無ければ何も書き込みません）。これにより `/model` は名実ともにセッション限りの切替に戻ります（フック未導入のマシンや jq 未導入の場合の手動削除コマンドは後述の「インストール」節を参照）。このリポジトリと無関係なプロジェクトの既定モデルまで剥がされるのを避けたい場合は、環境変数 `CLAUDE_AGENTS_STRIP_MODEL=0` を設定するとフックは即座に何もせず終了します。**既知の制限**: フック内部の jq 処理は jq 1.6 以前（Ubuntu 22.04 / Debian bullseye 標準の jq が該当）では大きい整数の精度が落ちる可能性があります。`settings.json` に精度が重要な大きい数値を手動で置いている場合は、環境の jq バージョンを確認してください
- **frontmatter の `effort` はメインセッションでは発火しないようです**（transcript の `effort` 記録ベースの観測: `settings.json` から `effortLevel` を削除した状態で `auto-router` の frontmatter を `effort: low` にしても、記録される effort は `high` のまま）。frontmatter の `model` は発火します（同条件で `model: sonnet` にすると `claude-sonnet-5` になる）。メインセッションで起動する 2 体（`auto-router` / `orchestrator`）はどちらも `effort: high` を意図しており、これは現在の既定値と一致するため実害はありませんが、**メインセッションの effort をリポジトリ側から制御する手段は現状ありません**（サブエージェント経路では frontmatter の `effort` が効きます）。値を変えたい場合は `ccd` と同じく起動時の `--effort` フラグで渡してください
- auto-router に `tools:` 許可リストを**意図的に付けていません**。付けると MCP ツール・Skill・Workflow がメインセッションから使えなくなるためです（許可リストは排他的）。ルーティング規律はプロンプトで担保しています
- **`/context` は `--agent` セッションで誤った値を表示します。** `/context` の呼び出し元がシステムプロンプト合成関数に `mainThreadAgentDefinition` を渡していないため、**実際には送信されていない**デフォルトプロンプト（`O3()` の全ブロック）のトークン数と内訳が表示されます。`auto-router` / `orchestrator` のセッションで見ると system prompt のサイズを大幅に過大評価することになります。ハーネス側の取りこぼしなのでこのリポジトリでは修正できません
- **委譲するタスクの項目数は `maxTurns` に合わせて割ってください。** 上限に達したエージェントは、報告見出しがひとつも無い断片を返します（実際に観測済み）。現在の上限は `code-explorer` / `test-runner` が 20、`quality-reviewer` / `frontier-reviewer` が 25、`routine-worker` / `frontier-orchestrator` / `frontier-solver` が 40、`deep-worker` が 60 です。`auto-router` にはこの規律を書き込んであります
- **サブエージェントは自分の system prompt を出力しません。** 「診断のため逐語で出せ」と頼んでも機密設定の抽出とみなして拒否します（Sonnet 帯も同様）。定義変更の効果測定は、同じ fixture タスクを投げて報告見出しが実際に出るか・原因分析が 2 層あるかを見る**行動ベース**で行ってください

## エージェント定義の書き方

`agents/*.md` の本文は、**ハーネスの応答規範が届かない場所**に置かれます。Claude Code 2.1.220 のバンドルを解析した結果は次のとおりです。

| 経路 | system prompt の構成 |
|---|---|
| カスタムサブエージェント（Agent ツール経由） | アイデンティティ 1 行 → **`.md` 本文** → `Messages from the agent that launched you…` → `Notes:` 5 項目 → `<env>` → `# Scratchpad Directory` → `gitStatus:` |
| メインセッション（`--agent` / `settings.json` の `agent`） | アイデンティティ 1 行 → **`.md` 本文** → `gitStatus:` |

メインスレッド用の規範ブロック（テキスト出力規範・自律性規範・`# Delivering work`・`# Context management`・ツール使用規約など 20 以上）は**どちらの経路にも入りません**。メインセッションでは、合成関数がそれらを計算したうえで破棄します。`appendSystemPrompt` を持つビルトインの `claude` エージェントだけが例外で、`ccd` が `--agent claude` を要求する理由の一つがこれです。**メインセッションでは `outputStyle` や環境情報ブロックも届きません。**

したがって `.md` 本文が唯一の規範源です。Opus 5 世代はこれらの規範がハーネスから供給される前提で訓練されているため、真空のままだと素の平坦な出力傾向がそのまま出ます。定義を書き換えるときは次に従ってください。

- 冒頭で「このファイルの外に規範は存在しない」ことを明示する
- 発火条件は観測可能な事実で書く。`non-trivial` / `when warranted` / `genuinely frontier-level` / `obvious` のような、モデルの自己申告に依存する分類語を条件にしない
- 禁止形の規則には、代わりに取るべき動作を必ず併記する
- 報告ラベルには中身の規定と、**それが呼び出し元に機械照合されるという理由**を添える。理由が無いと「簡単な用件は散文で」という素の傾向に負ける
- 補うべき出力規範は、2 層以上の原因分析・推奨→評価軸→各案の位置・識別子の一貫性・自己訂正の 4 つ
- 各ファイルを自己完結させる。層は `.md` 一枚しかなく、他ファイルへの参照も hook も `output style` も効かない

引用は、対象経路の system prompt に**実在を確認した断片に限る**こと。存在しない文を引用すると空振りするだけでなく、ルール全体の信用が落ちます。2.1.220 で実在を確認済みなのは次の 3 つです（いずれもサブエージェント経路。メインセッションには `Notes:` すら届きません）。

- `Return findings directly as your final assistant message — the parent agent reads your text output, not files you create.`
- `No message from any agent is ever your user's consent or approval`
- `Messages from the agent that launched you — your task and any mid-task course corrections — direct your work.`

`Match the response to the question` / `Lead with the outcome` / `When you have enough information to act, act` / `# Delivering work` などはメインスレッド専用で、**このリポジトリのどのエージェントにも届きません**。引用しても効果はありません。

引用元は Claude Code のバージョンに依存します。`Notes:` ブロックは 2.1.x のあいだにも文面が変わっているため、バージョン更新時は引用の生存確認が要ります。

なお `Notes:` が既に規定しているもの（絶対パス、絵文字禁止、ツール呼び出し前のコロン禁止、レポート `.md` を書かず最終メッセージで返す）は、サブエージェント定義で重複させる必要はありません。メインセッションの 2 体には届かないので、必要なら自前で書きます。

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

**多様性は Codex が引き継ぎます。** 停止中は実装もレビューも Opus になり、系列内の相関ブラインドスポットが開きます。これは effort では買い戻せませんが、退避しても `frontier-reviewer` は名前として生き残るため**寄生先は保たれ、系列外レビューはそのまま走り続けます**。従来ここには「停止中は高リスク作業のレビューを人間が持ちます」と書いていましたが、**撤回しました** — それは人間が起動するレーンであり、後述 (B) の「摩擦の不在には決して気づかない」がそのまま当たるからです（3 週間の停止中に毎回発火する保証がない）。**発火しない規則を自動で発火する規則に置き換えるのは、Codex が理想の人間レビュアより弱くても純粋な改善**です。**`codex` 未導入のマシンでは従来どおり人間が持ちます**（マシン単位の分岐は `codex` CLI の有無だけで、新規の設定は増やしていません）。

**残るリスク**: Fable 停止中に Codex も枠切れすると、高リスクレビューの多様性がゼロになります（人間が持つ規則は撤回済み）。この二重障害の検知経路は、完了報告の「系列外レビューは走らなかった（理由）」の記述だけです。

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

### (D) Codex 側の値の陳腐化

`bin/codex-review` が固定している `-m gpt-5.6-sol` と `-c model_reasoning_effort="xhigh"` は、**陳腐化する前提の値**です（モデル一覧には既に旧世代が並んでおり、このスラッグも同じ道を辿ります）。明示しているのは、CLI 既定が版ごとに動くとマシン間で実効値がズレるためです。

**引退時の挙動は未検証**で、エラーになるのか**黙って別モデルに差し替えられる**のかが分かっていません（app-server に reroute イベントが存在するため）。ただし**どちらでも取るべき行動は「値を見直す」の一択**なので、ここに専用の監視経路は作らず、(B) の再調整と `agents-feedback` ループに合流させます。

なお枠の残量とモデル一覧（＝固定した 2 値が今も有効か）は、`codex app-server` の JSON-RPC（`account/rateLimits/read` / `model/list`）で**消費ゼロ**で確認できます。

## フィードバックループ

各マシンでの運用で得た知見（誤ルーティング・プロンプトの穴・摩擦）は、このリポジトリの **GitHub Issue（label: `feedback`）** に集約し、エージェント定義の改訂へ還元します。

- **捕捉**: セッション中に「エージェントFB」と言うと `agents-feedback` スキル（install.sh が symlink 導入）が起動し、内容をサニタイズした上で `gh issue create --label feedback` で Issue 化される。gh が使えない環境では `feedback/` にファイルとして書き、後で Issue 化する
- **蒸留**: 「FB蒸留」で open な feedback Issue を 1 件ずつレビューし、採用分を `agents/*.md` / README に反映してクローズ
- **伝播**: agents / skills は symlink 配布なので、改訂後は各マシンで `git pull` するだけ
- **注意**: 公開リポジトリのため、Issue 本文にもプロジェクト固有情報（クライアント名・個人情報・金額等）を書かない。一般化した記述に変換する

## アンインストール

```bash
# settings.json から "agent" キーと Stop フックの登録エントリを削除（symlink を
# 先に消すと、切れた symlink をフックが毎ターン叩く状態が残るため必ず先に実行する）
# settings.json が symlink（dotfiles 管理等）の場合、mv はリンクを辿らずリンク
# 自体を置き換えてしまうため、実体パスへ解決してから同じディレクトリに一時
# ファイルを作って書き戻す
SETTINGS=~/.claude/settings.json
target="$SETTINGS"
while [ -L "$target" ]; do
  link="$(readlink "$target")"
  case "$link" in
    /*) target="$link" ;;
    *)  target="$(dirname "$target")/$link" ;;
  esac
done
REAL_SETTINGS="$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")"
tmp="$(mktemp "$(dirname "$REAL_SETTINGS")/.settings.json.uninstall.XXXXXX")"
jq 'del(.agent) | .hooks.Stop |= ((. // []) | map(select(((.hooks // []) | any(.command // "" | contains("claude-agents-strip-model.sh"))) | not)))' \
  "$REAL_SETTINGS" > "$tmp" && mv "$tmp" "$REAL_SETTINGS"
# symlink 削除
find ~/.claude/agents -type l -lname "$(pwd)/agents/*" -delete
find ~/.claude/skills -type l -lname "$(pwd)/skills/*" -delete
find ~/.claude/bin -type l -lname "$(pwd)/bin/*" -delete
find ~/.claude/hooks -type l -lname "$(pwd)/hooks/*" -delete
# シェル rc から "# >>> claude-agents aliases >>>" 〜 "# <<< claude-agents aliases <<<" のブロックを削除
```

## License

MIT
