# Opus 5 / Fable 5 / Sonnet 5 — 能力・コスト・上限消費・レイテンシ比較

- 調査日: 2026-07-25
- 対象 Issue: [#5](https://github.com/Fumiya-Matsumoto/claude-agents/issues/5)（親: #3）
- 判定したい問い: (i) Opus 5 は Fable の代替になりうるか / (ii) Sonnet 帯を Opus に上げたときのコストは何倍か
- 目的関数: **品質優先**。制約 (a) プランのレート制限に日常的に当たらない (b) ルーターのレイテンシが許容範囲

## 凡例

| ラベル | 意味 |
|---|---|
| **CONFIRMED** | Anthropic 一次情報（公式ドキュメント / 公式アナウンス / ヘルプセンター）に明記 |
| **INFERRED** | 一次情報から導出した推論。導出過程を併記し、反証可能にする |
| **UNKNOWN** | 一次情報が見つからなかった。推測で埋めていない |

## 情報源の鮮度について

- **Opus 5 は 2026-07-24 リリース**（System Card 表紙日付が `July 24, 2026`）。本調査の一次情報はすべて Opus 5 リリース後に取得したもの。
  - System Card: https://www-cdn.anthropic.com/c5fbac3f0b1280a933ebd26d3cb8bb9f5bdeaf48/Claude%20Opus%205%20System%20Card.pdf
- リポジトリ同梱の `claude-api` スキルは、モデル一覧テーブルに `cached: 2026-06-24` と自己申告しているが、本文には Opus 5 の移行ガイド・破壊的変更・`server-side-fallback-2026-07-01` まで含まれており、Opus 5 リリース後の内容。**価格・モデル ID はスキルと公式ドキュメントの双方で一致を確認済み**。
- 以下で「Opus 5 リリース前の情報源」と明示したもの以外は、すべて 2026-07-25 時点で取得した現行ページ。

---

## 1. 公表ベンチマーク差（コーディング / エージェント / 長い推論）

### 1-1. Opus 5 vs Fable 5 — **CONFIRMED（ただし相対表現のみ）**

出典: [Introducing Claude Opus 5](https://www.anthropic.com/news/claude-opus-5)

| ベンチマーク | 公表内容（原文の要旨） |
|---|---|
| 総括 | Opus 5 は「Claude Fable 5 のフロンティア知能に迫る性能を、半額で」提供する |
| CursorBench 3.2 | 「Fable 5 のピークスコアの 0.5% 以内、ただしタスクあたりコストは半分」 |
| OSWorld 2.0（computer use） | 「Fable 5 のベスト結果を上回る。コストは 1/3 強」 |
| Frontier-Bench v0.1（コーディング） | 全モデルを上回る。「Opus 4.8 の性能を 2 倍以上に、しかもタスクあたり低コストで」 |
| ARC-AGI 3（新規問題解決） | 「次点モデルの 3 倍のスコア」 |
| Zapier AutomationBench（業務タスク完遂） | 「同一タスクコストで次点モデルの約 1.5 倍の pass rate」 |
| GDPval-AA / Frontier-Bench | コーディング・ナレッジワーク評価で state-of-the-art |
| サイバーセキュリティ | 「Mythos 5 には及ばない」 |
| ライフサイエンス | 有機化学で Opus 4.8 比 +10.2 ポイント、タンパク質タスクで +7.7 ポイント |
| 安全性 | 自動行動監査で「overall misaligned behavior 2.3、直近モデル中で最低」 |

公式ドキュメント側の記述（[What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5)）:

> "Claude Opus 5 is a step-change improvement over Claude Opus 4.8, with the largest gains in deep reasoning, agentic and long-horizon tasks, and test-time compute scaling."
> "it delivers frontier intelligence at half the cost of Claude Fable 5"

改善が最大の領域として明記されているもの: deep reasoning / agentic coding & long-horizon tasks / test-time compute scaling / **低 effort での効率**（`low`・`medium` が「高 effort の何分の一かのトークンとレイテンシで強い品質」）/ code review & bug-finding（「低 effort でも精度が落ちない」）/ vision / long-context（1M フル幅で指示追従が一貫）/ multi-agent coordination（writer-verifier パターンが機能し、サブエージェント同士の上書き事故が少ない）。

> ⚠️ **注意**: 上表は Anthropic 自身の公表値であり、いずれも「Fable 5 比の絶対スコア表」ではなく相対表現。**Opus 5 と Fable 5 の同一ベンチマーク上の生スコアを並べた公式表は見つからなかった（UNKNOWN）**。CursorBench 3.2 の「0.5% 以内」が最も直接的な近接性の根拠。

### 1-2. Fable 5 の位置づけ — **CONFIRMED**

出典: [Introducing Claude Fable 5 and Claude Mythos 5](https://platform.claude.com/docs/en/about-claude/models/introducing-claude-fable-5-and-claude-mythos-5)

> "Claude Fable 5 is Anthropic's most capable widely released model, built for the most demanding reasoning and long-horizon agentic work."

Claude Code 側の記述（[Model configuration](https://code.claude.com/docs/en/model-config)）:

> "Claude Fable 5 is the most capable model in Claude Code, suited to tasks larger than a single sitting. It sustains long autonomous sessions, investigates before acting, and verifies its work more often than smaller models."

Fable を活かす条件として明記されているもの: 手順ではなく**成果（outcome）**を渡す / 曖昧な問題（根本原因調査・障害デバッグ・アーキテクチャ判断）を渡す / 検証の念押しは不要 / 通常なら分割するサイズの仕事をまとめて渡す。

**→ Fable の優位性は「1 セッションを超える長さの自律作業」に寄っている。** 逆に言えば、短いターンで終わる作業に Fable を割り当てても差は出にくい、というのが公式の立て付け。

### 1-3. Sonnet 5 — **CONFIRMED（数値は画像内のため一部 UNKNOWN）**

出典: [Introducing Claude Sonnet 5](https://www.anthropic.com/news/claude-sonnet-5)

> Sonnet 5 の「performance is close to that of Opus 4.8, but at lower prices」。Sonnet 4.6 からの大幅改善。

- ベンチマーク比較表は**画像として掲載されており、テキストで数値が取得できない（UNKNOWN）**。テキストで拾えたのは Sonnet 4.6 側の値（Humanity's Last Exam 34.6% / tools ありで 46.8%、OSWorld-Verified 78.5%）と、exploit development で Sonnet 系はいずれも 0.0% という記述のみ。
- **Sonnet 5 と Opus 5 / Fable 5 を直接比べた公表数値は、Sonnet 5 のアナウンスページには存在しない（UNKNOWN）**。Sonnet 5 の比較対象は Sonnet 4.6 と Opus 4.8。

### 1-4. この節の結論（判断材料として）

- **CONFIRMED**: エージェント / 長期ホライズン / コーディングという、このリポジトリが最も使う軸で、Opus 5 は Fable 5 に「近い」と Anthropic 自身が主張している（CursorBench で 0.5% 以内、OSWorld では上回る）。
- **CONFIRMED**: Fable 5 が明確に上位を保つと公式が述べている領域は、**サイバーセキュリティ（実際は Mythos 5 が上位）** と、Claude Code ドキュメントが言う「1 セッションに収まらないサイズの自律作業」。
- **INFERRED**: frontier-solver / frontier-reviewer のように「1 ターンで完結する難問解決 / レビュー」に近い用途では、Opus 5 で品質が実質同等になる可能性が高い。一方 frontier-orchestrator のような「長時間・多エージェント統括」は Fable の設計上の得意領域と重なるため、置換の妥当性は他 2 者より弱い。
  - 導出根拠: 1-1 の CursorBench/OSWorld の近接性 + 1-2 の Fable ポジショニング文。
  - **反証可能性**: これは公式が「orchestrator 用途で Fable > Opus 5」と述べたわけではない。Opus 5 側も "multi-agent coordination" を改善領域に挙げているため、実測すれば逆転しうる。

---

## 2. API 価格（入出力トークン単価）— **CONFIRMED**

| モデル | モデル ID | 入力 $/MTok | 出力 $/MTok | コンテキスト | 最大出力 |
|---|---|---|---|---|---|
| Claude Fable 5 | `claude-fable-5` | **$10.00** | **$50.00** | 1M | 128K |
| Claude Opus 5 | `claude-opus-5` | **$5.00** | **$25.00** | 1M（既定かつ最大） | 128K |
| Claude Sonnet 5 | `claude-sonnet-5` | **$3.00**（導入価格 $2.00、2026-08-31 まで） | **$15.00**（導入価格 $10.00） | 1M | 128K |

出典:
- Opus 5: [What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5) — "priced at $5 per million input tokens and $25 per million output tokens, unchanged from Claude Opus 4.8"
- Fable 5: [Introducing Claude Fable 5 and Claude Mythos 5](https://platform.claude.com/docs/en/about-claude/models/introducing-claude-fable-5-and-claude-mythos-5) — "$10 USD per million input tokens and $50 USD per million output tokens"
- Sonnet 5: [Introducing Claude Sonnet 5](https://www.anthropic.com/news/claude-sonnet-5) — 導入価格 "$2 per million input tokens and $10 per million output tokens"（2026-08-31 まで）、通常 "$3 / $15"
- リポジトリ同梱 `claude-api` スキルのモデル表とも一致

### 2-1. 単価比（**INFERRED** — 単純な割り算）

| 比 | 入力 | 出力 |
|---|---|---|
| Opus 5 ÷ Sonnet 5（通常 $3/$15） | 1.67× | 1.67× |
| Opus 5 ÷ Sonnet 5（導入価格 $2/$10） | 2.50× | 2.50× |
| Fable 5 ÷ Opus 5 | 2.00× | 2.00× |
| Fable 5 ÷ Sonnet 5（通常） | 3.33× | 3.33× |

> ⚠️ **これは「同じトークン数を消費した場合」の比でしかない。** 実際の請求額 / 上限消費は「単価 × 実消費トークン数」であり、後者はモデルごとに大きく異なる（3-3 参照）。単価比を上限消費倍率としてそのまま使うと**過小評価**になる。

### 2-2. Fast mode 価格 — **CONFIRMED**

出典: [Fast mode](https://platform.claude.com/docs/en/build-with-claude/fast-mode)

| モデル | Fast mode 入力 | Fast mode 出力 |
|---|---|---|
| Opus 5 | $10 / MTok | $50 / MTok |
| Opus 4.8 | $10 / MTok | $50 / MTok |
| Opus 4.7 | $30 / MTok | $150 / MTok（2026-07-24 に削除済み） |

Fast mode は **Claude API（Managed Agents 含む）限定**。Bedrock / Google Cloud / Microsoft Foundry では利用不可。Batch API・Priority Tier とも併用不可。

---

## 3. サブスクリプションプランのレート制限に対する消費重み（**最重要**）

### 3-1. 結論を先に

> **Anthropic は「Opus は Sonnet の N 倍消費する」という数値の乗数を公表していない（UNKNOWN）。**
> 公表されているのは (a) 定性表現、(b) Fable に対する 50% キャップ、(c) モデル別の別枠上限が存在するという事実の 3 点。

### 3-2. 公表されている定性表現 — **CONFIRMED**

出典: [Models, usage, and limits in Claude Code](https://support.claude.com/en/articles/14552983-models-usage-and-limits-in-claude-code)

> "Opus costs several times more per turn than Sonnet, and Sonnet more than Haiku."
> "Sonnet is the default and is the right choice for the large majority of coding work."

出典: [Claude Fable 5 on your plan](https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan)

> "Fable 5 draws from your plan's regular weekly usage limits and **uses them faster than other Claude models**."

出典: [How do usage and length limits work?](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)

> "Your usage is affected by several factors, including the length and complexity of your conversations, the features you use, **which Claude model you're chatting with, and the effort level you've selected**."

**→ 「モデル」と「effort」の両方が上限消費に効くことは公式に明言されている。数値は一切公表されていない。**

### 3-3. プラン構造として確認できた事実 — **CONFIRMED**

| 事実 | 出典 |
|---|---|
| 全プランに 5 時間ローリングのセッション上限があり、有料プランはその上に週次上限が乗る | [Usage limit best practices](https://support.claude.com/en/articles/9797557-usage-limit-best-practices)、[Manage costs effectively](https://code.claude.com/docs/en/costs) |
| **Max プランには週次上限が 2 本ある**: 「全モデル横断」と「Sonnet 系のみ」 | [What is the Max plan?](https://support.claude.com/en/articles/11049741-what-is-the-max-plan) |
| Claude Code のセッション/週次上限は**全モデル共有**。`/model` でモデルを変えても回復しない | [Manage costs effectively](https://code.claude.com/docs/en/costs) — "These windows are shared across all models, so switching models with `/model` doesn't restore access" |
| ただし**「You've hit your Opus limit」という Opus 固有のメッセージが存在**し、そこからはモデルを下げれば作業継続できる | 同上 — "though it does keep the developer working after the model-specific 'You've hit your Opus limit' message" |
| **Max プラン等では Fable 5 は週次上限の最大 50% までしか使えない** | [Claude Fable 5 on your plan](https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan) — "You can use up to 50% of your weekly usage limits on Fable 5 at no extra cost." |
| **Pro プランでは Fable 5 はプラン上限に含まれず、usage credits（従量課金）扱い** | 同上 — "Fable 5 isn't included in your plan's usage limits. You can use Fable 5 with usage credits" |
| Fable 5 を週次上限に含めるプロモーションは 2026-07-19 23:59:59 PT で終了済み | 同上 |
| Claude Code のエージェントチーム（複数インスタンス）は plan mode で標準セッションの約 7 倍のトークンを使う | [Manage costs effectively](https://code.claude.com/docs/en/costs) — "approximately 7x more tokens than standard sessions" |

**この構造から読み取れる、アーキテクチャ判断に直結する 3 点:**

1. **Sonnet 専用の週次枠が存在する** → Sonnet 帯のエージェントを Opus に昇格させると、Sonnet 専用枠を使い残したまま「全モデル横断枠」だけを食い潰す。**枠の使い残しが発生する**という、単なる倍率とは別種のコストがある。これは制約 (a) に対して単価比より重い意味を持つ。
2. **Opus には固有の上限メッセージがある** → Opus 帯を厚くすると「Opus 上限だけ先に枯れる」モードに入りやすい。ただし枯れてもモデルを下げれば作業は続く（ハードストップではない）。
3. **Fable は 50% キャップ + 「他モデルより速く消費する」** → frontier-* 3 体を Fable のまま維持することは、Max プランでも週次枠の半分を天井とする運用になる。Pro プランなら**プラン外の従量課金**。

### 3-4. API レート制限のモデル別テーブル（サブスクではないが、公表された唯一の数値的なモデル別差） — **CONFIRMED**

出典: [Rate limits](https://platform.claude.com/docs/en/api/rate-limits)

| Tier | モデル | RPM | ITPM | OTPM |
|---|---|---|---|---|
| Start | **Fable 5** | 1,000 | **500,000** | **100,000** |
| Start | Opus 5 | 1,000 | 2,000,000 | 400,000 |
| Start | Sonnet 5 | 1,000 | 2,000,000 | 400,000 |
| Build | **Fable 5** | 2,000 | **1,500,000** | **300,000** |
| Build | Opus 5 | 5,000 | 5,000,000 | 1,000,000 |
| Build | Sonnet 5 | 5,000 | 5,000,000 | 1,000,000 |
| Scale | **Fable 5** | 4,000 | **4,000,000** | **800,000** |
| Scale | Opus 5 | 10,000 | 10,000,000 | 2,000,000 |
| Scale | Sonnet 5 | 10,000 | 10,000,000 | 2,000,000 |

同ページの脚注（原文）:

> "Opus rate limit is a total limit that applies to combined traffic across Claude Opus 4.8, Opus 4.7, Opus 4.6, and Opus 4.5. **Claude Opus 5 has a separate rate limit and is not part of this combined bucket.**"
> "Sonnet 4.x rate limit is a total limit that applies to combined traffic across Sonnet 4.6 and Sonnet 4.5. **Claude Sonnet 5 has a separate rate limit and is not part of this combined bucket.**"

**読み取れること（API 課金の場合）:**
- **Opus 5 と Sonnet 5 の API レート制限は同一枠サイズ**（Start で 2M ITPM / 400k OTPM）。API で Sonnet→Opus 5 に上げても、レート制限の「枠の大きさ」自体は変わらない。
- **Fable 5 だけが 1/4 の枠**（Start で 500k ITPM / 100k OTPM）。Fable はレート制限上、他の 2 モデルより 4 倍窮屈。
- キャッシュ読み出しトークンは ITPM に**カウントされない**（Haiku 3.5 を除く）。プロンプトキャッシュが効く設計はレート制限上の実効スループットを大きく押し上げる。

> ⚠️ **これは API（Console / 従量課金）のレート制限であって、Pro/Max サブスクの上限ではない。** サブスク側の数値は非公開。ただし「Fable だけ枠が 1/4」「Opus 5 と Sonnet 5 は同枠」という Anthropic 自身の枠設計の考え方は、サブスク側の設計思想を推測する材料にはなる（が、それは INFERRED）。

### 3-5. 価格から上限消費を導出した推論（**INFERRED** — 反証してほしい部分）

一次情報に数値乗数がない以上、判断材料を作るには推論するしかない。以下は**推論であって事実ではない**。

**推論 A: 上限消費が list price に比例すると仮定した場合の倍率**

- 仮定: サブスクの usage 計上は、内部的にトークン × モデル単価（またはそれに比例する何か）で行われている。
- 導出: 2-1 の単価比がそのまま上限消費倍率になる。
  - Sonnet 5 → Opus 5: **1.67×**（Sonnet 通常価格ベース） / **2.5×**（Sonnet 導入価格ベース）
  - Opus 5 → Fable 5: **2.0×**
- **この推論を疑うべき理由**:
  1. Anthropic は上限消費の算定式を公表していない。単価連動である保証はない。
  2. Sonnet 5 の $2/$10 は 2026-08-31 までの**導入価格**。仮に単価連動なら、9/1 に Opus/Sonnet の消費比が 2.5× → 1.67× に「勝手に改善する」ことになる。上限消費が導入価格に連動していると考えるのは不自然で、この仮定自体が怪しい。
  3. Max プランに「Sonnet 専用枠」が存在する事実は、単純な単価連動ではなくモデルクラス別のバケット設計であることを示唆する。

**推論 B: 実消費トークン量の差を加味した場合（推論 A より重い）**

一次情報で確認できる、Opus 5 が**同じ仕事でも Sonnet より多くトークンを吐く**要因:

| 要因 | 出典（CONFIRMED） |
|---|---|
| Opus 5 は **thinking が既定でオン**（Opus 4.8 は既定オフ）。thinking トークンは出力トークンとして課金される | [What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5) |
| Opus 5 は「既定のユーザー向け応答と成果物が**長くなる**」 | 同上 — "Default user-facing responses and written deliverables run longer." |
| Opus 5 は agentic セッションで「進捗をより頻繁にナレーションする」 | 同上 |
| Opus 5 は「**サブエージェントにより積極的に委譲する**」 | 同上 — "In multi-agent frameworks, it delegates to subagents more readily." |
| Opus 5 は「言われなくても自分の作業を検証する」（過剰検証になりうるので検証指示は削除すべき） | 同上 |
| コーディング / エージェント用途の推奨 effort は **`xhigh`**（Sonnet 5 の既定は `high`） | [Effort](https://platform.claude.com/docs/en/build-with-claude/effort) |

- 導出: 上限消費倍率 = 単価比 × トークン量比。単価比が 1.67–2.5× であることは確からしいが、**トークン量比が 1.0 を大きく超える方向の要因が公式に列挙されている**ため、実効倍率は単価比を上回る。
- **反証可能性**: トークン量比の数値は公式にない。「委譲を増やす」はサブエージェント側のモデル次第でコストが変わるため、単一の倍率にはならない。effort を `medium`/`low` に落とせば逆方向に効く（Opus 5 は「`low`/`medium` が従来 Opus より強い」と公式が明記しているため、この打ち手は現実的）。

**推論 C: 制約 (a) に対する実務的な結論**

- Sonnet 帯 5 体（auto-router / orchestrator / code-explorer / routine-worker / test-runner）を全部 Opus に上げるのは、**Sonnet 専用週次枠を丸ごと捨てる**ことになるため、単価比 1.67× より実質的に高くつく。**少なくとも 1 体は Sonnet に残す設計のほうが、同じ品質予算で枠を使い切れる。**
- 特に auto-router は毎ターン走るため、ここを Opus に上げると全モデル横断枠への圧力が最も大きい。
- Fable 3 体の維持コストは、Max プランなら「週次枠の 50% まで」というハード上限に守られている（=それ以上は自動的に食い潰せない）。**制約 (a) の観点では Fable は思ったほど危険ではない**（キャップが効くため）。むしろ危険なのは**キャップのない Opus 帯の膨張**。
- **反証可能性**: 50% キャップに当たった時の挙動（Fable が使えなくなるだけか、それとも作業が止まるか）は未確認（UNKNOWN）。

---

## 4. レイテンシ傾向

### 4-1. Opus 5 — **CONFIRMED**

- **既定で thinking がオン**（Opus 4.8 は既定オフ）。つまり **Opus 4.8 と同じコードでもレイテンシは増える方向**。
  - [What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5): "On Claude Opus 4.8, requests run without thinking unless you set `thinking: {"type": "adaptive"}`. On Claude Opus 5, the same requests run with thinking on"
- **`low` / `medium` effort が従来 Opus より強い**、かつ「トークンコストと応答時間の主要な制御手段として積極的に使え」と公式が推奨:
  - [Effort](https://platform.claude.com/docs/en/build-with-claude/effort): "`low` and `medium` effort are stronger on Claude Opus 5 than on earlier Opus models: **use them liberally as your primary control for token cost and response time** wherever your evals show quality holds"
  - 同ページ: "If you carried effort settings over from an earlier model, **run a fresh effort sweep** on your evals rather than reusing them."
- **thinking の無効化は effort `high` 以下でのみ許可**。`xhigh`/`max` で `thinking: {"type": "disabled"}` を送ると 400 エラー（破壊的変更）。
- Fast mode: 出力トークン毎秒が最大 **2.5×**。ただし **TTFT（最初のトークンまでの時間）は改善しない**。
  - [Fast mode](https://platform.claude.com/docs/en/build-with-claude/fast-mode): "Speed benefits are focused on output tokens per second (OTPS), not time to first token (TTFT)"
  - Claude API 限定（Bedrock / Google Cloud / Foundry では不可）、research preview、アクセスは要申請（waitlist / account manager）。

### 4-2. Fable 5 — **CONFIRMED**

- effort が「知能・レイテンシ・コストのトレードオフの主制御」。既定は `high`。
  - [Effort](https://platform.claude.com/docs/en/build-with-claude/effort): "Reduce effort if a task completes but takes longer than necessary, **or if you want a faster, more interactive working style**."
- thinking は**常時オン、無効化不可**（`thinking: {"type": "disabled"}` は非サポート）。
- `claude-api` スキルの記述: 難タスクでは単一リクエストが**数分単位**で走ることがあり、タイムアウト / ストリーミング / 進捗 UX の設計が必要。
- **Fable 5 は Fast mode 非対応**（Fast mode は Opus 5 / 4.8 / 4.7 のみ）。

### 4-3. Sonnet 5 — **CONFIRMED**

- Claude API / Claude Code のいずれでも既定 effort は **`high`**。
- レイテンシ重視なら `low`:
  - [Effort](https://platform.claude.com/docs/en/build-with-claude/effort): "**Low effort:** For high-volume or latency-sensitive workloads. Suitable for chat and non-coding use cases where faster turnaround is prioritized."
- `medium` は「Sonnet 4.6 の `high` 相当」（公式の対応づけ）。
- Sonnet 5 も **`xhigh` をサポート**（Sonnet 帯で初）。
- **Sonnet 5 は Fast mode 非対応**。

### 4-4. ルーター（毎ターン走る）に関する追加の一次情報 — **CONFIRMED**

- **effort を変えるとプロンプトキャッシュが無効化される**:
  - [Effort](https://platform.claude.com/docs/en/build-with-claude/effort): "Because effort shapes the rendered prompt, changing it between requests does not preserve cached prefixes from earlier turns; if you rely on prompt caching across a long session, **pick an effort level at the start and keep it constant**."
  - → auto-router の effort を動的に変える設計は、キャッシュミス経由でレイテンシ・上限消費の両方を悪化させる。**固定すべき。**
- **キャッシュ最小長**: Opus 5 は **512 トークン**（Opus 4.8 は 1,024）。短いプロンプトでもキャッシュが効くようになった。
  - [What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5)
- サブスクのキャッシュ寿命は **1 時間**（usage credits に入ると 5 分に落ちる。API / クラウドプロバイダは既定 5 分）:
  - [Manage costs effectively](https://code.claude.com/docs/en/costs)

### 4-5. レイテンシ比較の限界 — **UNKNOWN**

**3 モデルの TTFT / トークン毎秒を並べた公式の数値表は存在しない。** 公表されているのは (a) Fast mode の 2.5× OTPS、(b) effort による相対的な制御という定性情報のみ。**「Opus 5 は Sonnet 5 より X ms 遅い」に相当する一次情報はない。**

---

## 5. 「Opus 4.8 が不安定」という前提の裏取り

### 5-1. 前提の出所

親 Issue #3 の Notes に記載:

> "**前提の失効**: 現アーキテクチャは「Opus 4.8 が不安定」「Sonnet を入口に」という前提で校正されている。"

**リポジトリ内（`README.md` / `agents/*.md`）を全文検索したが、「Opus 4.8 が不安定」と書かれた箇所は存在しない**（`grep -rniE "opus|4\.8|不安定"` で該当なし）。つまりこの前提はコードベースに明文化されておらず、オーナーの運用上の体感として Issue #3 に記録されているもの。

### 5-2. Anthropic 一次情報での裏取り結果

**Opus 4.8 が不安定だったと Anthropic が認めた一次情報は見つからなかった（UNKNOWN）。**

むしろ Opus 4.8 のアナウンスは逆の主張をしている（**Opus 5 リリース前の情報源**）:

出典: [Introducing Claude Opus 4.8](https://www.anthropic.com/news/claude-opus-4-8)

> "Early testers have found Claude Opus 4.8 to be **more reliable and sharper in its judgment** when it's performing agentic tasks."
> "Claude Opus 4.8 delivers the intelligence and **reliability** to be your daily driver for serious coding and knowledge work."
> Opus 4.6 を改善し、「Opus 4.7 で見られた comment-verbosity と tool-calling の問題を修正した」

つまり Anthropic の公表ラインでは、**不安定だったのは Opus 4.7**（コメント冗長・ツール呼び出しの問題）であり、4.8 はその修正版という位置づけ。

### 5-3. 「Opus 5 で解消された」と言える一次情報はあるか

**部分的にある。ただし弱い。**

- **CONFIRMED（ただし顧客の声の引用であり、Anthropic の計測値ではない）**: [Introducing Claude Opus 5](https://www.anthropic.com/news/claude-opus-5) に、ある顧客が Opus 5 について「以前のバージョンと比べて **far less variance run to run**」「reliable results, build after build」と述べたという記述がある。
- **CONFIRMED**: [What's new in Claude Opus 5](https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5) は Opus 4.8 比を "step-change improvement rather than an incremental one" と表現し、"code review and bug-finding, surfacing real bugs at a high rate per pass with **few false positives**, and staying accurate at lower effort levels" を改善領域に挙げている。
- **CONFIRMED（安全性の指標として）**: 自動行動監査で「overall misaligned behavior 2.3、直近モデル中で最低」。

**判定:**

| 問い | 答え |
|---|---|
| 「Opus 4.8 は不安定だった」を裏づける Anthropic 一次情報はあるか | **NO（UNKNOWN）**。むしろ公式は 4.8 を reliability の売りで出しており、不安定と名指しされているのは 4.7。 |
| 「Opus 5 でその不安定さが解消された」と言える一次情報はあるか | **弱い YES**。顧客引用の "far less variance run to run" が最も直接的。Anthropic 自身の run-to-run 分散の計測値は非公表（UNKNOWN）。 |

> **したがって、この前提の扱いについての推奨（INFERRED）**: 「Opus 4.8 が不安定」は一次情報で裏が取れない**運用上の体感**として扱うべきで、アーキテクチャ校正の根拠としては弱い。Issue #3 が既に「失効した前提」として扱う方針を出しているのは、一次情報の状況と整合している。ただし「Opus 5 なら安定している」も、一次情報としては**顧客引用 1 件**にしか支えられていない。**どちらの向きにも強い一次情報はない**ので、Opus 5 への昇格は「4.8 の不安定さが直ったから」ではなく、**1 節のベンチマーク差と 3 節の上限構造**を根拠に判断するのが筋が通る。

---

## 6. 判定材料のまとめ

### (i) Opus 5 は Fable の代替になりうるか

| 観点 | 材料 | ラベル |
|---|---|---|
| コーディング品質 | CursorBench 3.2 で Fable のピークの 0.5% 以内、コストは半分 | CONFIRMED |
| エージェント / computer use | OSWorld 2.0 で Fable のベストを上回る（コスト 1/3 強） | CONFIRMED |
| 長期ホライズン自律作業 | Fable は「1 セッションを超えるサイズ」向けと公式が位置づけ。Opus 5 も長期ホライズンを最大改善領域に挙げている | CONFIRMED（両方） |
| セキュリティ分析 | Opus 5 は Mythos 5 に及ばない（Fable/Mythos 系が上位） | CONFIRMED |
| 上限消費 | Fable は Max で週次枠の 50% キャップ、Pro では従量課金。「他モデルより速く消費」 | CONFIRMED |
| 可用性リスク | **Fable 5 は 2026-06-12 〜 2026-07-01 の約 3 週間、全ユーザーに対してアクセス停止された**（米政府の輸出規制対応。国籍のリアルタイム検証手段がないため全面停止） | CONFIRMED |
| レイテンシ | Fable は Fast mode 非対応。Opus 5 は Fast mode 対応（OTPS 2.5×、要申請） | CONFIRMED |

**→ 材料としては「Opus 5 は Fable の代替として十分現実的」寄り。** 特に、単なるベンチマーク差以外に **Fable 固有の運用リスク 2 つ**（50% 週次キャップ / 3 週間の全面停止実績）が一次情報で確認できたのが大きい。逆に Fable を残すべき明確な根拠は「サイバーセキュリティ」と「1 セッションを超えるサイズの自律作業」。

出典（可用性リスク）: [Redeploying Claude Fable 5](https://www.anthropic.com/news/redeploying-fable-5)

### (ii) Sonnet 帯を Opus に上げたときのコスト

| 何を問うか | 答え | ラベル |
|---|---|---|
| API 単価倍率 | 1.67×（Sonnet 通常価格）/ 2.5×（Sonnet 導入価格、2026-08-31 まで） | CONFIRMED（価格）+ INFERRED（割り算） |
| サブスク上限消費倍率 | **Anthropic は数値を公表していない** | UNKNOWN |
| 公表されている定性表現 | "Opus costs several times more per turn than Sonnet" | CONFIRMED |
| 実効倍率は単価比より高いか | 高い方向。thinking 既定オン / 応答長増 / ナレーション増 / 委譲増 / 推奨 effort が `xhigh` | INFERRED（要因は CONFIRMED、倍率は不明） |
| API レート制限の枠サイズ | **Opus 5 と Sonnet 5 は同一枠**（Start で 2M ITPM / 400k OTPM）。Fable のみ 1/4 | CONFIRMED |
| 見落とされがちな構造コスト | Max には **Sonnet 専用の週次枠**があり、Sonnet 帯を空にするとその枠を使い残す | CONFIRMED |

---

## 7. 未解決（UNKNOWN）一覧 — 追加調査 or 実測が必要

1. **サブスクプランのモデル別上限消費乗数** — 公表なし。実測（`/usage` の内訳、`d`/`w` トグル）でしか埋まらない。
2. **Opus 5 と Fable 5 の同一ベンチマーク上の生スコア表** — 公式には相対表現のみ。
3. **Sonnet 5 のベンチマーク数値** — アナウンスページの表が画像で、テキスト抽出不可。
4. **3 モデルの TTFT / トークン毎秒の実測値** — 公式の比較表なし。ルーターの体感レイテンシは実測が必要。
5. **Fable の 50% 週次キャップに当たった時の挙動** — 停止するのか、フォールバックするのか未確認。
6. **Pro / Max 各プランの週次上限の絶対値** — Anthropic は数値を公表していない（「Max 5x は Pro の 5 倍」等の相対表現のみ）。
7. **`claude.com/pricing` のプラン比較表のモデル行** — 自動抽出が不安定で、Pro での Fable の扱いを表から確定できなかった。ヘルプセンター記事（[Claude Fable 5 on your plan](https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan)）の記述を採用した。

---

## 8. 付随して確認できた、割当変更時に効く事実（CONFIRMED）

`agents/*.md` は `model: sonnet|opus|fable` というエイリアスを使っているため、以下は割当変更の前提として重要。

出典: [Model configuration](https://code.claude.com/docs/en/model-config)

| エイリアス | Anthropic API での解決先 |
|---|---|
| `sonnet` | **Sonnet 5** |
| `opus` | **Opus 5** |
| `fable` | Claude Fable 5 |
| `best` | 組織が Fable 5 にアクセスできれば Fable 5、なければ最新 Opus |
| `haiku` | 最新 Haiku |
| `opusplan` | plan mode で `opus`、実行時に `sonnet` へ切替 |

- **`opus` が Opus 5 に解決されるには Claude Code v2.1.219 以降が必要。** v2.1.219 より前は `opus` = Opus 4.8。
- Sonnet 5 は v2.1.197 以降、Fable 5 は v2.1.170 以降が必要。
- Bedrock / Google Cloud では `sonnet` が Sonnet 4.5、Microsoft Foundry では `opus` が Opus 4.6 に解決される（プロバイダ依存）。**Anthropic API 直なら上表どおり。**
- **Fable 5 は ZDR（zero data retention）下では利用不可。** 30 日データ保持が必須。
- Opus 5 のコンテキストは **1M が既定かつ最大**（小さいバリアントは存在しない）。`opus[1m]` エイリアスは Opus 5 では実質意味を持たない。Sonnet 5 も 1M がネイティブ。
  - → Issue #3 の "Not yet specified" にある「1M context をどのエージェントに割り当てるか」という論点は、**Opus 5 / Sonnet 5 / Fable 5 のいずれも 1M ネイティブなので、モデル選択とは独立した論点ではなくなった**（INFERRED、ただし根拠は CONFIRMED な仕様）。
- Claude Code の `ultracode` は API の effort レベルではなく、**`xhigh` + マルチエージェント起動の常設許可**の組み合わせ。
  - 出典: [Effort](https://platform.claude.com/docs/en/build-with-claude/effort)

---

## 参照した一次情報 URL 一覧

- https://www.anthropic.com/news/claude-opus-5
- https://www-cdn.anthropic.com/c5fbac3f0b1280a933ebd26d3cb8bb9f5bdeaf48/Claude%20Opus%205%20System%20Card.pdf
- https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5
- https://platform.claude.com/docs/en/about-claude/models/introducing-claude-fable-5-and-claude-mythos-5
- https://www.anthropic.com/news/claude-sonnet-5
- https://www.anthropic.com/news/claude-opus-4-8
- https://www.anthropic.com/news/redeploying-fable-5
- https://platform.claude.com/docs/en/build-with-claude/effort
- https://platform.claude.com/docs/en/build-with-claude/fast-mode
- https://platform.claude.com/docs/en/api/rate-limits
- https://code.claude.com/docs/en/model-config
- https://code.claude.com/docs/en/costs
- https://support.claude.com/en/articles/15424964-claude-fable-5-on-your-plan
- https://support.claude.com/en/articles/14552983-models-usage-and-limits-in-claude-code
- https://support.claude.com/en/articles/11049741-what-is-the-max-plan
- https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work
- https://support.claude.com/en/articles/9797557-usage-limit-best-practices
- https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan
- https://claude.com/pricing
- https://claude.com/blog/claude-model-and-effort-level-in-claude-code
- リポジトリ同梱 `claude-api` スキル（モデル ID / 価格 / パラメータの権威的参照）
