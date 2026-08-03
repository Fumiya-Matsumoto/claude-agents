# claude-agents

Claude Code の**判断の質でルーティングするエージェント構成**。入口は **Fable 5 のルーター**で、タスクが必要とする判断の質に応じて 4 Tier に振り分けます。加えて Herdr 等のマルチペイン運用を前提としたオーケストレーターエージェントのセットです。

最適化しているのはコストではなく**判断の質の配り方**です（安いモデルへ寄せることは目的ではありません）。

思想: **Fable は仕事の量ではなく、判断が起きる場所に置く。** 入口のルーティング、司令塔、正解が未知の難問、高リスク変更のレビューはいずれも判断そのものが成果物なので Fable が座り、量のある実装はそこに溜めず下位 Tier へ渡す（Tier 0 を狭く保つ規定はこのためにある）。正解が明確になった瞬間、実行は可能な限り下位モデルへ戻す。

## アーキテクチャ

**Tier は「必要な判断の質」で分けます。モデル帯は軸ではなく結果です。**

```text
claude（全セッション共通の入口）
  │
  ▼
auto-router (Fable) ── 必要な判断の質でタスクを 4 Tier に分類
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

### Tier 3 ゲート — 依頼時点の不確実性と実行中の不確実性の分離

Tier 3 に上がる前に、ルーターは不確実性の発生時点を判定します:

- **依頼時点から存在する不確実性**（新機能の仕様化・作り直し・アーキテクチャ依頼）→ 昇格せず停止し、**決定セッション**（`ccd` で起動する、ルーターを着せない素の対話セッション）を推奨。サブエージェントは実行中にユーザーへ質問できないため、Tier 3 内で決まる設計はユーザー承認をバイパスしてしまう
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

**レビューは「変更」に対して 1 回であり、「完了状態」に対してではありません。** 以前の規定は「修正すれば新しい完了サイクルが生まれ、レビューが自動で再発火する」と書いていましたが、これには停止条件が無く、実運用で**同一タスクに 5 巡**回りました。3 巡目以降は本体コードの指摘がゼロで、レビュー主題が「本体」から「テスト足場」へ移った後も同じ重さのフルレビューが回り続けています。**レビューを重ねるほど品質が上がるのではなく、対象が本体から足場へ移った時点で費用対効果が反転します。**

現在は再発火の判定に**新しい規則を置かず、既存の発火条件を修正それ自体に当てます** — テスト補助コードの Minor 修正は単体では条件を満たさないので走らず、認可経路の書き直しに相当する修正は単体でも高リスクなので走ります。

**指摘の裁定はルーターが行い、可視性で担保します。** 採用・却下とも全件を原文のまま完了報告に列挙し、却下には理由を付けます。これは系列外レビュー（Codex）と Claude 側レビュアの**双方**に掛かります。以前は Codex 側にしか裁量規定が無く、規定の無い Claude 側は既定動作として Minor / Nit まで逐一ユーザーに諮る運用になり、往復が指摘件数に比例して増えていました。

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
| auto-router | Fable | xhigh | 入口。Tier 分類とルーティング（メインセッション用） |
| orchestrator | Fable | xhigh | マルチペイン運用の管理専任（実装しない、メインセッション用） |
| code-explorer | Sonnet | high | 読み取り専用のコード探索・事実収集 |
| routine-worker | Sonnet | xhigh | 定型実装・テスト・機械的リファクタ |
| test-runner | Sonnet | high | テスト・型検査・lint の実行と要約 |
| deep-worker | Opus | max | 難デバッグ・複雑実装（方針確定済みで実行が難しいもの） |
| quality-reviewer | Opus | xhigh | Tier 2 の独立レビュー ＋ 高リスクな Tier 1 |
| frontier-orchestrator | Fable | xhigh | Tier 3 司令塔。Edit/Write なし、判断と委譲に専念 |
| frontier-solver | Fable | xhigh | 正解自体が不明な難問のみ（低頻度） |
| frontier-reviewer | Fable | xhigh | 高リスク変更の独立レビュー（falsify 指向） |

`quality-reviewer` / `frontier-reviewer` による独立レビューが走る場面では、加えて**系列外の `codex exec review`（OpenAI Codex CLI・任意）が並行で走ります**。これは Claude のサブエージェントではないので frontmatter を持たず、この表には載りません（前節「系列外レビュー（Codex）」を参照）。

モデル列は frontmatter の `model:` エイリアス（`sonnet` / `opus` / `fable` = それぞれ現行世代に解決される）。effort の配り方は次の原則で決めています:

- **どの帯の消費も共通枠を食う** — Max の週次上限は「全モデル共通枠」と「Fable 枠」（共通枠の 50% でハードキャップ）の 2 本（`/usage` の実測）。**Sonnet 専用の枠は存在しない**ので、Sonnet 帯の effort 増もコストはゼロではない。上げた分は共通枠から出ている。Fable 枠を引く側の性質は 2026-08 に変わった。それまでは Tier 3 ゲートに守られた `frontier-*` 3 体と使い捨ての `ccd` だけで、どちらも低頻度だったが、メインセッション 2 体が Fable になったことで**毎ターン積算する消費がハードキャップ側に乗った**。逼迫したときに何から切るか（後述の (B)）はこれを前提にしている
- **品質不足は摩擦として検出できない** — 遅さは体感されるが、実装の品質不足は「難しい仕事だった」としか見えず、差し戻しとレビュー往復に化けて遅れて現れる。**間違えたときに気づけないほうを避ける**ので、測定が無い場面では上げる側に倒す。`deep-worker` の `max` はこの原則によるもので、下げ代（`max` → `xhigh`）は逼迫時のロールバック梯子に残る
- **ただしこの非対称はレビュアには当てはまらない** — レビュアの出力は採否を裁くために直接読まれるので、質の低さはその場で見える。加えてレビュアは完了報告の直前に**同期でクリティカルパスに乗る**（実装の時間は「どのみち待つ時間」の置き換えだが、レビューの待ちは純増）。`quality-reviewer` を `max` で 1 回走らせたところ **15.8 分**かかったため `xhigh` へ戻した。**実測を根拠に下げた唯一の値**であり、根拠は品質への留保ではなく待ち時間
- **常時走るものとタスクごとに1回走るものを分ける** — サブエージェントの effort はタスクあたり 1 回しか乗らないが、メインセッションの effort は全ターンに積算する。ただしメインセッション 2 体の `xhigh` は、この積算を嫌って選んだ値ではない。`settings.json` の `effortLevel` は enum が `low` / `medium` / `high` / `xhigh` で `max` を表現できず、メインセッションでは frontmatter の `effort` が発火しないため、`auto-router` の天井がそもそも `xhigh` である。`orchestrator` だけは `cco` の `--effort` フラグで天井を超えられるが、2026-08 に `max` から `xhigh` へ下げた。以前の根拠は枠（起動頻度が `auto-router` の約 1/5 なので積算の母数が小さい、transcript 実測）だったが、週次上限に日常的に当たっていない以上、枠は上げる理由にも下げる理由にもならない。**枠が制約でなくなると残る軸は待ち時間だけになり、待ち時間は下げる側に効く。** 指示文発行・PR 検証・マージはどれも人間が画面の前で待つ 100% クリティカルパスで、出力はその場で読まれて採否が決まるので、直前の `quality-reviewer` の実測がそのまま当たる（`orchestrator` 自身の所要時間は測っていない）。加えて Fable 化そのものがベースラインを上げたぶん、`max` の限界深度が買えるものは Opus のときより小さい

> **effort の優先順位は実測で確定しています（2026-07-30）: `--effort` フラグ > `settings.json` の `effortLevel` > frontmatter の `effort`。**
> メインセッションでは frontmatter の `effort` は発火しません（`effortLevel: low` を置くと frontmatter `high` の `auto-router` が `low` で起動する）。一方 **サブエージェントは frontmatter が発火し、`settings.json` に潰されません**（同条件で `code-explorer` は frontmatter どおり `high` で起動）。
> したがって上表のうち `auto-router` / `orchestrator` の値は frontmatter だけでは実現せず、`settings.json` の `effortLevel` とエイリアスの `--effort` が実効値を決めます（次節を参照）。2 体とも `xhigh` になった今は `settings.json` の `effortLevel: xhigh` だけで実効し、`cco` の `--effort xhigh` はプロジェクト側の `.claude/settings.json` が `effortLevel` を上書きした場合への保険として残ります。frontmatter にも同じ値を書いてあるのは、この 2 体がサブエージェントとして起動された場合に効かせるためです。

## ペイン運用（Herdr 等のマルチペイン環境向け・任意）

| エイリアス | 展開先 | ペイン |
|---|---|---|
| `cco` | `claude --permission-mode auto --agent orchestrator --effort xhigh` | **O 管理**: 指示文発行・PR 検証・マージ・追跡専任。`orchestrator` の frontmatter により Fable で走る。effort はメインセッションで frontmatter が発火しないため、`--effort xhigh` フラグで明示している（値は `settings.json` の `effortLevel` と同じで、プロジェクト側に上書きされたときの保険）。起動時に状況同期が自動で走る |
| `ccd` | `claude --permission-mode auto --model fable --agent claude --effort high` | **D 決定**: 仕様策定・計画・敵対的検証。**規模を問わず計画はここ**。ルーターを着せない素の Fable 対話であり、Tier 3 ゲートが指す決定レーン。決定 1 件で使い捨て |
| `ccw` | `claude --permission-mode auto -w` | **W 実装**: セッション専用 worktree で実装〜PR 作成。`ccw <name>` で worktree に名前も付けられる。`-w` は値を省略できる引数を取るため、必ず末尾に置く（`-w` より後ろに置いた引数だけが worktree 名として拾われる。フラグを `-w` より前に置かないと `ccw <name>` の `name` が worktree 名にならず、初回プロンプトとして送信されてしまう） |

シングルペイン運用でも auto-router 単体で完結します（ペイン運用は任意）。

**メインセッションが Fable になっても `ccd` は残ります。** 上表の `ccd` 行には以前「Fable をメインスレッドで使う唯一の入口」と書いていましたが、既定のメインセッションが Fable になったのでこの説明は偽になりました。`ccd` が買っているのはモデルの差ではなく、ルーターを着せない素の対話であることと、Tier 3 ゲートが「昇格せず停止して推奨せよ」と指す決定レーンであることの 2 つです。ゲートの根拠は承認権限（サブエージェントは実行中にユーザーへ質問できない）なので、モデルが揃っても成立し続けます。

**`ccd` の `--agent claude` は必須です。** `settings.json` の `"agent": "auto-router"` は `--model` を渡しても効き続けるため、これが無いと D ペインは「Fable の上に auto-router を着せた」セッションになります。すると (1) Tier 3 ゲートが「停止して決定セッションを推奨せよ」と命じるのに自分がその決定セッションである、(2) 代わりに `frontier-orchestrator` へ委譲するとサブエージェントはユーザーに質問できないので、承認権限を根拠に守った境界が決定ペインの中でこそ破れる、という 2 つの自己矛盾が起きます。ビルトインの catch-all エージェント `claude` を明示して素の Fable 対話へ戻します。**`--model fable` も外せません。** `claude` はこのリポジトリのファイルではなく frontmatter の `model` を持たないので、既定のメインセッションが Fable になった今も、外せばモデルの指定そのものが消えます。

**憲章は広く取り、深さは据え置き**（`--effort high`）。仕様化・計画・敵対的検証は規模を問わず D ペイン、難しいだけの実装・調査・デバッグは既定のメインセッションで足ります。境界を難易度ではなく**仕事の種類**で引いているのは、難易度では境界がもう引けないからです。D ペインと既定のメインセッションは同じ Fable なので、「難しいから D ペインへ」と言っても手に入るモデルは変わりません（以前は Opus と Fable の差がわずかに残っていて、それでもほとんど D ペインを引かない理由になっていました）。残る差は `--agent claude` によるルーターの有無と、実行中にユーザーへ質問できるかどうかだけで、これは仕事の種類にしか対応しません。

> 既にインストール済みの環境では、エイリアスはシェル rc に**書き込み済み**です（install.sh はマーカーで冪等なので上書きしません）。`cco` / `ccd` / `ccw` の定義は rc 側を手で更新してください。

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
4. `hooks/*` を `~/.claude/hooks/` へ **symlink**（`settings.json` から `"model"` を剥がし、`"effortLevel"` を `"xhigh"` に正規化する `claude-agents-strip-model.sh`。理由は後述の「注意」を参照）
5. `~/.claude/settings.json` に `"agent": "auto-router"` と `"effortLevel": "xhigh"` を設定（要 jq、バックアップ作成。`effortLevel` が既にあり値が異なる場合は上書きしたうえで元の値を表示する）。加えて `Stop` フックへ `claude-agents-strip-model.sh` を追記登録する（既存の `Stop` / `SessionStart` エントリは保持したまま追記。コマンド文字列で既存判定するため再実行しても重複登録されない）。以降は Stop フックが `"model"` を剥がし `"effortLevel"` を `"xhigh"` へ正規化し直すため、`/model` と `/effort` はどちらも**恒久化しなくなる**（`/effort` の切替がセッション限りか 1 ターン限りかは未確認。「注意」節を参照）。`"model"` が残っていれば、次のターンでフックが自動的に消す旨と手動削除コマンドを表示する。同じ手順で `permissions.defaultMode` も `"auto"` に設定する（既存値が異なれば上書きしたうえで元の値を表示する）。`settings.json` は machine-local で配布されないためマシンごとに設定が要ること、`defaultMode: "auto"` は user settings（`~/.claude/settings.json`）でのみ有効でプロジェクト側の `.claude/settings.json` / `.claude/settings.local.json` に書かれた `auto` は Claude Code v2.1.142 以降無視されること、user settings は優先順位が最下位でプロジェクト側の `defaultMode` に負けうるためエイリアス側の `--permission-mode auto`（CLI フラグ、最優先）と二重に張っていること、の 3 点が理由（詳細は前節「ペイン運用」を参照）
6. シェル rc に `cco` / `ccd` / `ccw` エイリアスを追加（マーカー付き・冪等）
7. `codex` CLI の有無を検出して表示（未導入でも中断しません。系列外レビューがスキップされるだけです）

symlink 方式なので、**agents / skills / bin / hooks 本体の更新は `git pull` だけ**で全マシンに反映されます。ただし例外が 3 つあります。

- **配布物が増えたとき**: `git pull` しても新しい symlink は張られません。系列外レビューの `bin/` は新しく増えた配布物なので、**既に導入済みのマシンでは `./install.sh` を 1 度だけ再実行してください**（冪等です）。再実行しない場合、`codex` が導入済みでもスクリプトが見つからず系列外レビューは走りません
- **`install.sh` が `settings.json` / シェル rc に書き込む内容が変わったとき**: これも `git pull` だけでは反映されず、**`./install.sh` の再実行が必要**です（冪等です）。直近では `cco` の `--effort max` → `--effort xhigh`（2026-08）と、`cco` / `ccd` / `ccw` への `--permission-mode auto` の追加、`settings.json` への `permissions.defaultMode` の設定がこれに該当します。とくに `--effort` を放置すると、O ペインが決定と違う深さで開き続けます。ただし**`cco` / `ccd` / `ccw` エイリアスは rc 側に既にマーカー付きブロックがある場合、install.sh は上書きせず警告と手動更新の案内を表示するだけです**（無断で rc を書き換えないため）。既にインストール済みの環境では、再実行後に表示される警告に従って `cco` / `ccd` / `ccw` エイリアスを手動で更新してください
- **このリポジトリを移動・リネーム・削除したとき**: `~/.claude/` 配下の symlink は絶対パスで張られているので全部切れます。特に `hooks/` の symlink が切れると、Stop フックが**毎ターン stderr を出し続けます**（応答自体は壊れません）。移動先で **`./install.sh` を再実行**してください。もう使わない場合は下の「アンインストール」を実行してから消してください

`CLAUDE_CONFIG_DIR` を設定している場合は、install.sh もフックもその値を設定ディレクトリとして使います（未設定なら `~/.claude`）。以下の説明では `~/.claude` と書きますが、設定していればそちらに読み替えてください。

### 前提

- Claude Code（Fable 5 が利用できるプラン）
- `jq`（settings.json の自動更新に使用。なければ手動追記の案内が出ます）
- bash / zsh
- **任意**: OpenAI Codex CLI（`codex`。系列外レビューに使用）。**未導入でも壊れません** — 系列外レビューがスキップされ、その旨が完了報告に明記されるだけです

**1 行目の要求は 2026-08 に重くなりました。** それまで Fable は一部機能の前提で、無くても入口と Tier 0〜2 は動き、`frontier-*` 3 体と `ccd` だけが死にました。メインセッション 2 体が Fable になった今は、**`claude` の素起動そのものが立ち上がりません**。つまり「Fable 5 が利用できるプラン」は、現在は構成全体の起動条件です。Fable が使えない状態でこのリポジトリを動かすなら、後述の「(A) Fable が使えないとき」の退避を最初から当てた状態にしてください。

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

- **model の真実の源は `agents/*.md` の frontmatter に一本化しています。** `settings.json` の `"model"` はメインセッションで frontmatter の `model` に**勝ちます**（実測: 優先順位は `--model` フラグ > `settings.json` > frontmatter）。`/model` などで書き込まれると割当が 2 箇所に分裂し、`settings.json` は machine-local で配布されないので必ずマシン間でズレます。frontmatter と違うモデルが要る場面（frontmatter を持たない `--agent claude` で開く `ccd` を含む）は `--model` フラグか `/model` で明示指定する設計です。**`/model` はもともとそのセッション限りの切替という意味論のコマンドですが、実行すると `settings.json` に書き込まれて恒久化してしまいます。** install.sh は `hooks/claude-agents-strip-model.sh` を `Stop` フックとして登録し、セッションが応答を終えるたびに `"model"` を自動で剥がし、`"effortLevel"` を `"xhigh"` へ正規化します（毎ターン走りますが、書き込みが必要な場合 ―― `"model"` が残っている、または `"effortLevel"` が `"xhigh"` 以外のとき ―― に限って settings.json へ書き込みます）。これにより `/model` は名実ともにセッション限りの切替に戻ります（フック未導入のマシンや jq 未導入の場合の手動削除コマンドは後述の「インストール」節を参照）。`"effortLevel"` の正規化についての詳細は次項を参照してください。このリポジトリと無関係なプロジェクトの既定モデルや effortLevel まで書き換えられるのを避けたい場合は、環境変数 `CLAUDE_AGENTS_STRIP_MODEL=0` を設定するとフックは即座に何もせず終了します（model・effortLevel 両方のオプトアウトが同じスイッチに束ねられています）。**既知の制限**: jq 1.6 以前（Ubuntu 22.04 / Debian bullseye 標準の jq が該当）では大きい整数の精度が落ちる可能性があります。フックだけでなく **install.sh も `settings.json` 全体を jq で読み書きして丸ごと書き戻す**ので、同じリスクがあります（`agent` / `effortLevel` / Stop フック登録の 3 回）。`settings.json` に精度が重要な大きい数値を手動で置いている場合は、環境の jq バージョンを確認してください。**もう 1 つの既知の制限**: フックは書き戻す直前に `settings.json` の mtime・サイズ・inode を取り直し、読み出した時点と一致する場合だけ置き換えます（compare-and-swap）。これで「フックが読んでから書くまでの間に Claude Code 本体が `/config` 等で書いた内容が丸ごと巻き戻る」事故は塞げますが、**完全ではありません** — mtime の粒度が 1 秒までのファイルシステムで、同一秒内に同じサイズのまま in-place 書き換えが起きた場合は検出できません（一時ファイル + rename で書くプロセスは inode が変わるので検出できます）。検出した場合フックは何もせずに降り、次のターンで再試行します。**フックが取るロック（`~/.claude/.strip-model.lock`）は相互排他の保証ではありません** — 60 秒より古いロックの奪取が生きたロックを掴んだ場合や、猶予時間を超えるプロセス停止（SIGSTOP・スリープ復帰）が挟まった場合には、2 つのフックが同時に走りえます。POSIX シェルに「inode が一致するときだけ削除する」原子操作が無いため原理的に閉じられない残余で、ロックは競合を減らすためだけのものです。**安全性を担保しているのは上記の compare-and-swap の方**で、ロックが失われても `settings.json` は壊れません（後着の書き込みが弾かれ、次のターンで再試行されます）。CAS が入った以上ロック自体を廃止できるのではないか、という検討は issue #39 で追跡しています
- **effort の真実の源は model と違い、経路で分かれます（次項の実測順位が根拠）。** サブエージェント 8 体は `settings.json` の `effortLevel` に潰されないため、frontmatter が唯一の指定手段です。一方メインセッション 2 体（`auto-router` / `orchestrator`）は frontmatter の `effort` がそもそも発火しないため、`settings.json` の `effortLevel` と起動時の `--effort` フラグが実効値を決めます。ただし**「唯一の手段」は言い過ぎです** — `settings.json` の `effortLevel` は project 階層のものが global（`~/.claude/settings.json`）に**勝つ**ため、プロジェクト側の `.claude/settings.json` に `effortLevel` を置けばそちらが実効します。また **`settings.json` の `effortLevel` は enum が `low` / `medium` / `high` / `xhigh` に限定されており `"max"` を表現できません**（不正値は黙って捨てられます）。メインセッション 2 体の `xhigh` が選んだ値ではなく天井なのはこのためで、フラグを持たない既定の入口（`claude`）は `xhigh` より上に行けません。**model と非対称なのはここが理由です** — model は「settings.json から剥がせば frontmatter に一本化される」という設計が成立しますが、effort はメインセッションに frontmatter という指定手段自体が存在しないため、単純に剥がすとメインセッション 2 体の effort を誰も制御できなくなります。したがって install.sh が `"effortLevel": "xhigh"` を能動的に設定したうえで、`hooks/claude-agents-strip-model.sh` が毎ターンそれを `"xhigh"` へ正規化し直します。`/effort` はセッション中いつでも打てますが、次の応答完了時に `settings.json` の値が `"xhigh"` へ戻るため、**その値が以後のセッションへ持ち越されることはありません**。**未確認**: 実行中のセッションの実効 effort が、フックの書き戻し後もそのターンの指定を保つのか、次のターンで `"xhigh"` に戻るのかは未検証です（バイナリには settings 再読込のサブスクライバと `/effort` が直接更新する UI 状態の両方があり、ターンごとのリクエストがどちらを見るか未追跡）。したがって切替の射程は「セッション限り」か「1 ターン限り」のどちらかで、**恒久化しないことだけが確定しています**。`cco` が `--effort xhigh` を明示しているのは、`--effort` フラグが `effortLevel` に勝つ性質を使って、プロジェクト側の `.claude/settings.json` による上書きから O ペインを守るためです（前節「ペイン運用」を参照）。**ただしこの守りは O ペインにしか掛かっていません。** プロジェクト側の `effortLevel: high` は `auto-router` も同じように引き下げますが、既定の入口（素の `claude`）にはエイリアスもフラグもないので、引き下げられたまま気付く手がかりがありません。`cco` だけが守られているのは、この露出が O ペインで小さいと判断したからではなく、`cco` には既にエイリアスがあってフラグを 1 つ足す追加コストがゼロだったからです。**既定の入口を同じように守るなら素の `claude` に対応するエイリアスを新設することになりますが、その是非は決まっていません**（入口をエイリアス経由にすると「エイリアスを通さない `claude` は守られない」という同じ穴が 1 段ずれて残るため、対処が対処になっているかがまだ検討できていない）。現状は**未クローズの露出**として置いてあります。旧来の根拠（`effortLevel` の enum が `max` を表現できないので `orchestrator` にはフラグが要る）は `orchestrator` 固有だったため、この非対称は自明でした。根拠を差し替えた結果として非対称が説明を失っている、というのがここに書いてある状態です
- **effort の優先順位は実測で確定しています（2026-07-30）: `--effort` フラグ > `settings.json` の `effortLevel` > frontmatter の `effort`。** メインセッションでは frontmatter の `effort` は発火しません（`effortLevel: low` を置くと、frontmatter が `high` の `auto-router` が `low` で起動する）。フラグはそれに勝ちます（同条件で `--effort max` は `max` で起動する）。一方 **サブエージェント経路では frontmatter が発火し、`settings.json` に潰されません**（同条件で `code-explorer` は frontmatter どおり `high` で起動する）。したがって**サブエージェント 8 体の effort は frontmatter が唯一の指定手段**であり、**メインセッション 2 体は `settings.json` の `effortLevel` と起動時フラグが実効値を決めます**。frontmatter にも同じ値を書いてあるのは、この 2 体がサブエージェントとして起動された場合に効かせるためです
- **`permissions.defaultMode` も machine-local な設定です。** `settings.json` は `~/.claude` 全体（マシン全体）に効くため、install.sh が設定する `permissions.defaultMode: "auto"` は、このリポジトリと無関係なプロジェクトのセッションにも影響します（`model` / `effortLevel` と同じ設計上の理由）。ただし auto mode は `bypassPermissions` とは別物です — 分類器が各ツール呼び出しごとにリスクを評価し、低リスクと判定したものだけを自動実行し、残りは通常どおりブロックする仕組みであって、全許可ではありません。この書き込みだけを無効化したい場合は、環境変数 `CLAUDE_AGENTS_SET_DEFAULT_MODE=0` を設定してください（`CLAUDE_AGENTS_STRIP_MODEL=0` と同じ発想・作法のオプトアウトです）。
- auto-router に `tools:` 許可リストを**意図的に付けていません**。付けると MCP ツール・Skill・Workflow がメインセッションから使えなくなるためです（許可リストは排他的）。ルーティング規律はプロンプトで担保しています
- **`/context` は `--agent` セッションで誤った値を表示します。** `/context` の呼び出し元がシステムプロンプト合成関数に `mainThreadAgentDefinition` を渡していないため、**実際には送信されていない**デフォルトプロンプト（`O3()` の全ブロック）のトークン数と内訳が表示されます。`auto-router` / `orchestrator` のセッションで見ると system prompt のサイズを大幅に過大評価することになります。ハーネス側の取りこぼしなのでこのリポジトリでは修正できません
- **`maxTurns` は全エージェントから外しました。** 以前は 20〜60 の上限を 8 体に付けていましたが、上限に達したエージェントは報告見出しがひとつも無い断片を `status: completed` として返すため、**呼び出し側が成果物を能動的に確認しない限り成功と誤読されます**。1 セッションで 5 回の打ち切りが観測され、うち 1 件は破壊的な検証手順の復元前に切られて欠陥が作業ツリーに残りました。外した決め手は配置です — 上限が無かったのは `auto-router` / `orchestrator`、つまり**タスクによる自然な終端を持たないメインセッション 2 体だけ**で、保護がリスクと逆向きに掛かっていました。暴走の記録は Issue 上に 1 件もありません
- **サブエージェントは自分の system prompt を出力しません。** 「診断のため逐語で出せ」と頼んでも機密設定の抽出とみなして拒否します（Sonnet 帯も同様）。定義変更の効果測定は、同じ fixture タスクを投げて報告見出しが実際に出るか・原因分析が 2 層あるかを見る**行動ベース**で行ってください

## エージェント定義の書き方

`agents/*.md` の本文は、**ハーネスの応答規範が届かない場所**に置かれます。Claude Code 2.1.220 のバンドルを解析した結果は次のとおりです。

| 経路 | system prompt の構成 |
|---|---|
| カスタムサブエージェント（Agent ツール経由） | アイデンティティ 1 行 → **`.md` 本文** → `Messages from the agent that launched you…` → `Notes:` 5 項目 → `<env>` → `# Scratchpad Directory` → `gitStatus:` |
| メインセッション（`--agent` / `settings.json` の `agent`） | アイデンティティ 1 行 → **`.md` 本文** → `gitStatus:` |

メインスレッド用の規範ブロック（テキスト出力規範・自律性規範・`# Delivering work`・`# Context management`・ツール使用規約など 20 以上）は**どちらの経路にも入りません**。メインセッションでは、合成関数がそれらを計算したうえで破棄します。`appendSystemPrompt` を持つビルトインの `claude` エージェントだけが例外で、`ccd` が `--agent claude` を要求する理由の一つがこれです。**メインセッションでは `outputStyle` や環境情報ブロックも届きません。**

したがって `.md` 本文が唯一の規範源です。現行世代のモデルはこれらの規範がハーネスから供給される前提で訓練されているため、真空のままだと素の平坦な出力傾向がそのまま出ます。定義を書き換えるときは次に従ってください。

- 冒頭で「このファイルの外に規範は存在しない」ことを明示する
- 発火条件は観測可能な事実で書く。`non-trivial` / `when warranted` / `genuinely frontier-level` / `obvious` のような、モデルの自己申告に依存する分類語を条件にしない
- 禁止形の規則には、代わりに取るべき動作を必ず併記する
- 報告ラベルには中身の規定と、**それが呼び出し元に機械照合されるという理由**を添える。理由が無いと「簡単な用件は散文で」という素の傾向に負ける
- 補うべき出力規範は、2 層以上の原因分析・推奨→評価軸→各案の位置・識別子の一貫性・自己訂正の 4 つ
- 各ファイルを自己完結させる。層は `.md` 一枚しかなく、他ファイルへの参照も hook も `output style` も効かない

#### 常時ロードされるプロンプトの予算

> **`agents/auto-router.md` に行を足す提案は、どの行を削るかと対で出すこと。対にできないなら、その提案は却下する。他のファイルにこの制約は掛けない。**

`auto-router.md` は 5 日で 139 行 → 273 行と倍増しました（`996e054` → `152e367`）。原因は個々の追加が間違っていたことではありません。**どの追加も局所的には正しく論証されていました** — 例えば系列外レビューを `COMPLETION` 節に置く判断は「分類分岐を増やすなという既存の制約が禁じたのは*分類*であって、完了義務はそれに当たらない」と正しく論証しています。**しかしトークンと注意力は、その行が分類分岐かどうかで区別しません。論証には予算が無いので、正しい論証を積み上げるだけで総量が壊れます。**

対象を `auto-router.md` に限るのは、コスト構造がそこに集中しているからです。**主セッションが input の 76.1%**、サブエージェント全体で 23.9%（実測）。`auto-router.md` は毎ターン読まれ、`agents/routine-worker.md` は呼ばれたときだけ読まれます。同じ 10 行でも乗り方が違うので、同じ予算を掛ける理由がありません。

**症状を直すときは、規則を足すより先に、原因になっている力を外せないか見てください。** 反対向きの力が 4 本ある場所に 1 本足しても、プロンプトは論理ではなく反復の重みで解決するので効きません（Tier 0 を狭く保つ修辞 2 本と、レビュー自動再発火の 1 文は、この理由で削除されました）。

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

Fable 5 には全面停止の実績があり（2026-06 に約 3 週間、輸出規制対応）、メインセッション 2 体・`frontier-*` 3 体・`ccd` が同時に死にます。**自動フォールバックは存在しません**（`--fallback-model` は `--print` 専用）。

**障害の性質は 2026-08 に変わりました。** それまでは入口が無事で、Tier 3 へ上がるか `ccd` を開いたときに初めて壊れていました。メインセッション 2 体が Fable になった今は、**`claude` の素起動と `cco` そのものが立ち上がりません**。検知は速くなり、作業中にエラーへ遭遇するのを待つ必要はなくなりますが、退避を終えるまで一切作業できません。

**発動**: 起動に失敗 → 1 回再試行 → 回復せず、かつ `claude --model opus -p 'ok'` が通る → **即退避。公式告知は待ちません**（告知を見に行く人はいないため）。probe は Fable 固有の停止と API 全体の不調を 10 秒で切り分けるためのもので、`--model` フラグと `--print` しか使わないので入口が死んでいても打てます。

**退避先は 4 つではなく 6 つ**:

| 対象 | 退避後 |
|---|---|
| `agents/auto-router.md` | `model: opus`（`effort` は触らない。メインセッションでは frontmatter が発火せず、`settings.json` の `effortLevel: xhigh` がそのまま実効する） |
| `agents/orchestrator.md` | `model: opus`（同上。`cco` の `--effort xhigh` が実効する） |
| `agents/frontier-orchestrator.md` | `model: opus` / `effort: max` |
| `agents/frontier-solver.md` | `model: opus` / `effort: max` |
| `agents/frontier-reviewer.md` | `model: opus` / `effort: max` |
| `ccd`（エイリアスは rc 側にあり repo 管理外） | `claude --permission-mode auto --model opus --agent claude --effort high` を直打ち |

**`cco` と `claude` の素起動には rc を触る必要がありません。** どちらも `--model` フラグを持たず、`settings.json` の `"model"` はフックが毎ターン剥がすので、frontmatter が実効値になります。上表の `agents/auto-router.md` / `agents/orchestrator.md` を書き換えれば両方とも Opus で開きます。rc の直打ちが要るのは `ccd` だけで、理由は `--agent claude` が frontmatter を持たず、モデルを `--model fable` フラグで与えているからです。

**commit しないのが要点です。** agents は symlink 配布なので作業ツリーを直接編集すれば即反映され、dirty な作業ツリーと `git status` がそのまま「今フォールバック中」の常時インジケータになります。main には意図した割当だけを残し、**復帰は `git checkout -- agents/` の 1 コマンド**（`claude --model fable -p 'ok'` が通ったら実行）。対象が 3 ファイルから 5 ファイルに増えても 1 コマンドのままで、`ccd` の rc だけが従来どおり手戻しです。

**`effort: max` にするのは `frontier-*` 3 体だけです。** Fable は共通枠の 50% でハードキャップされているので、停止すればその消費が丸ごとゼロになり共通枠に余りが出ます。`max` の原資は停止で浮いた Fable 枠そのものです。メインセッション 2 体に同じことをしない理由は原資ではなく買うものの側にあります。`auto-router` は `effortLevel` の enum が `max` を表現できないので上げようがなく、`orchestrator` は `cco` の `--effort` を書き換えれば上げられますが、`xhigh` へ下げた根拠は枠ではなく待ち時間でした。停止は人間が画面の前で待つ時間を 1 秒も短くしないので、`max` を買う余地はそもそも生まれません。

**多様性は Codex が引き継ぎます。** 停止中はルーティングも実装もレビューも Opus になり、系列内の相関ブラインドスポットが開きます。これは effort では買い戻せませんが、退避しても `frontier-reviewer` は名前として生き残るため**寄生先は保たれ、系列外レビューはそのまま走り続けます**。従来ここには「停止中は高リスク作業のレビューを人間が持ちます」と書いていましたが、**撤回しました** — それは人間が起動するレーンであり、後述 (B) の「摩擦の不在には決して気づかない」がそのまま当たるからです（3 週間の停止中に毎回発火する保証がない）。**発火しない規則を自動で発火する規則に置き換えるのは、Codex が理想の人間レビュアより弱くても純粋な改善**です。**`codex` 未導入のマシンでは従来どおり人間が持ちます**（マシン単位の分岐は `codex` CLI の有無だけで、新規の設定は増やしていません）。

**残るリスク**: Fable 停止中に Codex も枠切れすると、高リスクレビューの多様性がゼロになります（人間が持つ規則は撤回済み）。この二重障害の検知経路は、完了報告の「系列外レビューは走らなかった（理由）」の記述だけです。

### (B) レート制限に日常的に当たるとき — 予算のロールバック

上限消費の倍率は非公開で「どちらが原因か測ってから決める」は原理的に実行できないため、**順序を先に決めてあります**:

1. **メインセッション 2 体を `model: opus` へ戻す**（頻度から戻す）
2. **`ccd` の憲章を「不可逆性で切る」へ縮小**（幅から戻す）
3. **`frontier-*` を `effort: xhigh` → `high`**（深さを戻す）
4. それでも当たる → **マップを引き直す**

順序は**頻度に構造的な上限があるか**で決めています。メインセッション 2 体にはゲートが無く、全セッションの全ターンに乗ります。`ccd` のゲートは**人間の習慣だけ**なので、これにも上限がありません。`frontier-*` だけがルーターの Tier 3 ゲートに守られた需要駆動の消費で、上限が構造から出ています。「キャップされている側は最後に切る」ので `frontier-*` が最後に残ります。安全だから買った品質を真っ先に捨てるのは論理の逆走です。

**1 段目は 2026-08 に足したものです。既存 3 段の相対順序は変えていません。** 順序を決めている基準（構造的な上限の有無）は変わっておらず、上限を持たない消費者が 1 つ増えただけだからです。それまで Fable 枠を引くのは `ccd` と `frontier-*` だけで、この梯子は Fable の消費を全部覆っていました。メインセッション 2 体が Fable になった今は覆っていません。しかも覆えていない側のほうが大きいと見込まれます。`frontier-*` は Tier 3 ゲートの先にしか現れず、`ccd` は決定 1 件で閉じるのに対し、既定のメインセッションは全セッションの全ターンに乗るからです。1 段目を飛ばして下の 2 段だけを踏むと、**消費の大半に手を付けないまま品質を削る**ことになります。

1 段目だけは「machine-local・即時・可逆な変更を先に」という副次的な基準に反します（`ccd` の憲章の縮小は rc 1 行で済むのに対し、frontmatter の変更は全マシンへの配布を伴う）。それでも先に置くのは、この操作が (A) の退避とまったく同じで、commit せず作業ツリーに残せば配布が起きず、復帰も `git checkout -- agents/` の 1 コマンドだからです。配布コストという反対理由が、この 1 段に限っては立ちません。

閾値は**主観**（「日常的に当たって煩わしい」）で構いません。ただし**一段降りたら `feedback` ラベルの Issue を open のまま立て、現在どの段にいるかを可視化**します。摩擦には気づいても**摩擦の不在には決して気づかない**ため、「当たらなくなったら戻す」は原理的に発火しないトリガーだからです。open な Issue は次の「FB蒸留」で自動的に俎上に載ります。

Fable の週次 50% キャップに**初めて**当たったときは、観測挙動（停止かサイレントフォールバックか）を `feedback` Issue に記録するだけにします。1 回当たるのは障害ではなく**ガードレールが設計どおり働いた状態**なので、ファイルは触りません。ただし記録だけで済ませられるのは、観測挙動がサイレントフォールバックだった場合に限ります。停止だった場合はメインセッション 2 体も同時に止まるため、記録に加えて上の 1 段目を踏み、枠が戻るまで凌ぎます。

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
# 0. このリポジトリを clone したディレクトリへ移動する。下の find は
#    "$(pwd)/agents/*" のように symlink の指す先をカレントディレクトリ基準で
#    組み立てるので、別ディレクトリで実行すると 1 つも消えないまま
#    「成功したように見える」
cd /path/to/claude-agents

# 1. settings.json から "agent" キー・"effortLevel" キー・"permissions.defaultMode"
#    キーと Stop フックの登録エントリを削除（symlink を先に消すと、切れた
#    symlink をフックが毎ターン叩く状態が残るため必ず先に実行する）
#    settings.json が symlink（dotfiles 管理等）の場合、mv はリンクを辿らず
#    リンク自体を置き換えてしまうため、実体パスへ解決してから同じディレクトリに
#    一時ファイルを作って書き戻す
#    注意: del(.agent, .effortLevel) および permissions.defaultMode の削除は
#    ハーネスの既定値に戻すだけであり、インストール前にユーザーが settings.json
#    に置いていた元の値には戻らない。元の値は install.sh が作成した
#    ~/.claude/settings.json.bak.<タイムスタンプ> に残っているので、必要なら
#    そこから手動で復元すること。permissions.defaultMode は .permissions から
#    その 1 キーだけを消し、ユーザーが元から持っていた .permissions.allow 等の
#    兄弟キーは残す。削除の結果 .permissions が空オブジェクトになった場合のみ
#    .permissions 自体も消す（インストール前が {"permissions":{}} のように
#    defaultMode 以外のキーを 1 つも持たない状態だった環境でも同様で、この場合
#    .permissions キー自体が消える）
#    注意: CLAUDE_AGENTS_SET_DEFAULT_MODE=0 でインストールした環境では install.sh が
#    permissions.defaultMode に一切触れていないため、この手順をそのまま実行すると
#    インストール前からユーザー自身が置いていた defaultMode の設定まで消えてしまう。
#    該当する場合は、下の jq 式のうち permissions.defaultMode を削除する節を外してから
#    実行すること。
#    全体を ( ) のサブシェルに入れてあるのは、作業用の変数を対話シェルに
#    残さないため。失敗時はメッセージを出して settings.json を変更せずに抜ける
(
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  target="$CLAUDE_DIR/settings.json"
  n=0
  while [ -L "$target" ]; do
    n=$((n + 1))
    # symlink ループを踏むと無限ループになるので段数で打ち切る
    [ "$n" -le 20 ] || { echo "symlink が 20 段を超えました（ループの可能性）。中断します。" >&2; exit 1; }
    link="$(readlink "$target")" || { echo "readlink に失敗: $target" >&2; exit 1; }
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname "$target")/$link" ;;
    esac
  done
  dir="$(cd "$(dirname "$target")" && pwd -P)" || exit 1
  real="$dir/$(basename "$target")"
  [ -f "$real" ] || { echo "settings.json の実体が見つかりません: $real" >&2; exit 1; }
  tmp="$(mktemp "$dir/.settings.json.uninstall.XXXXXX")" || exit 1
  if jq 'del(.agent, .effortLevel)
      | .hooks.Stop |= ((. // []) | map(select(((.hooks // []) | any(.command // "" | contains("claude-agents-strip-model.sh"))) | not)))
      | if (.permissions? | type) == "object" then
          (.permissions |= del(.defaultMode))
          | if (.permissions | length) == 0 then del(.permissions) else . end
        else . end' \
      "$real" > "$tmp"; then
    mv "$tmp" "$real"
  else
    # 失敗したら隠しファイルを残さない
    rm -f "$tmp"
    echo "jq に失敗しました。settings.json は変更していません。" >&2
    exit 1
  fi
)

# 2. symlink 削除。設定ディレクトリの決め方は手順 1 と同じ（CLAUDE_CONFIG_DIR が
#    あればそちら）。-print を付けてあるのは、find が対象ゼロでも成功するため
#    ―― 何も表示されなければ 1 本も消えていない（＝ cd 先が違う、または既に
#    アンインストール済み）と分かるようにするため
(
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  for sub in agents skills bin hooks; do
    find "$CLAUDE_DIR/$sub" -type l -lname "$(pwd)/${sub}/*" -print -delete
  done
)

# 3. フックのロック残骸を掃除する。通常は残らないが、フックが奪取の途中で
#    SIGKILL された場合に .strip-model.lock.stale.* が残ることがある。フック側の
#    回収は「次に settings.json への書き込みが必要になったとき」にしか走らないので、
#    アンインストール時はここで消しておく（マッチしないときのエラーは捨てる）
(
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  rm -f "$CLAUDE_DIR"/.strip-model.lock/token "$CLAUDE_DIR"/.strip-model.lock.stale.*/token 2>/dev/null
  rmdir "$CLAUDE_DIR"/.strip-model.lock "$CLAUDE_DIR"/.strip-model.lock.stale.* 2>/dev/null
  true
)

# 4. シェル rc から "# >>> claude-agents aliases >>>" 〜 "# <<< claude-agents aliases <<<" のブロックを削除
```

## License

MIT
