# ChatGPT Plus における Codex の利用上限の構造 — 一次情報 + 実機実測

- 調査日: 2026-07-25
- 対象 Issue: [#17](https://github.com/Fumiya-Matsumoto/claude-agents/issues/17)（親: #15）
- 実機: `codex-cli 0.145.0`（`codex --version`）
- 契約プラン: **ChatGPT Plus** — 推測ではなく実測。app-server が `"planType": "plus"` を返す（§6）
- **本調査ではクォータを 1 も消費していない。** モデル推論は 1 回も走らせていない。読んだのは (a) 過去セッションが `~/.codex/sessions/**/*.jsonl` に記録済みの rate-limit スナップショット、(b) app-server の `account/rateLimits/read` / `account/usage/read`（アカウントのメタデータ読み取り。推論は走らない）、(c) 同梱バイナリの文字列とプロトコルスキーマ、(d) OpenAI 一次情報、の 4 つ

## 凡例

| ラベル | 意味 |
|---|---|
| **CONFIRMED(実測)** | このマシンの実データ（記録済みスナップショット / app-server の応答 / 同梱バイナリ）で確認 |
| **CONFIRMED(docs)** | OpenAI 一次情報（公式ドキュメント / ヘルプ / `openai/codex` ソース）に明記 |
| **INFERRED** | 実測または一次情報から導出した推論。導出過程を併記し、反証可能にする |
| **UNKNOWN** | 裏が取れなかった / 検証にクォータ消費が要るため未検証。推測で埋めていない |

> **実測がドキュメントに勝つ。** 前マップに前例がある（#3「前提の訂正」— support ページの「Sonnet 専用の週次枠」という記述が `/usage` の実測に反証された）。**本調査でも同じことが起きた**（§1）。

### 一次情報の所在についての注意

- `developers.openai.com/codex/pricing` は 2026-07-25 時点で **`https://learn.chatgpt.com/docs/pricing` へ 308 リダイレクト**する。以降これを正規の価格・上限ドキュメントとして参照する。
- `help.openai.com` は素の HTTP 取得に 403 を返す。取得はプロキシ経由。「Codex をあなたの ChatGPT プランで使う」記事は 2026-07-23 頃更新。

---

## 0. 結論（先に答える）

| 質問 | 答え | 確度 |
|---|---|---|
| 1. 上限の単位と本数 | **今このアカウントには週次枠が 1 本だけ**。5 時間枠は 2026-07-12〜07-17 の間に消えた（**公式ドキュメントは今も 5 時間枠があると書いている**）。モデル別ではなく `limit_id = "codex"` の全モデル共通枠 | CONFIRMED(実測) |
| 2. 消費の主因 | **入力トークン量**（＝ diff とコンテキストの大きさ）。公式レートカードで重みが確定: 出力は fresh input の 6 倍、cached input は fresh の 1/10。実測すると **credits の 8〜22% しか出力が占めない** → **effort を high→xhigh に上げても消費増は +5〜10% 程度** | CONFIRMED(docs+実測) |
| 3. 超過時の挙動 | **ハードストップ**（進行中のターンだけは完走させる）。`UsageLimitReached` は非リトライ。**サイレントな下位モデルへのフォールバックは存在しない** | CONFIRMED(docs+実測) |
| 4. 中規模 PR レビュー 1 回 | **週次枠の 0.5〜1.5%**（= 30〜85 credits） | INFERRED |
| 5. Plus と Pro の差 | **ちょうど 5 倍（Pro 5x）/ 20 倍（Pro 20x）**。Business は Plus と同一 | CONFIRMED(docs) |

**受け入れ基準への答え（「1 日 n 回回して上限に当たるか」）:**

> **n が 10 のオーダーなら当たらない。n が 100 のオーダーなら当たる。**
>
> 週次枠 100% ≒ **6,000 credits ≒ 2×10⁸ トークン**。レビュー 1 回 ≒ 0.5〜1.5%。つまり**週 70〜200 回 = 1 日 10〜30 回**が理論上限で、Codex を対話でも使う前提なら**1 日 5〜10 回**が実務上の安全線。

---

## 1. 上限の単位と本数（Issue 質問 1）

### 1-1. 【ドキュメントとの食い違い / 実測を採用】5 時間枠は、今このアカウントには存在しない

**公式ドキュメントは今も 5 時間枠があると書いている** — CONFIRMED(docs)、`https://learn.chatgpt.com/docs/pricing`:

> "The usage limits for local messages and cloud chats share a **five-hour window**. Additional weekly limits may apply."

Plus の公表値（ローカルメッセージ / 5 時間あたり）:

| モデル | Plus |
|---|---|
| GPT-5.6 Sol | 15〜90 |
| GPT-5.6 Terra | 20〜110 |
| GPT-5.6 Luna | 50〜280 |
| GPT-5.5 | 15〜80 |

**実機はこれと一致しない** — CONFIRMED(実測)。app-server から取得した**現在のライブ値**（2026-07-25、§6 の手順）:

```json
{
  "limitId": "codex",
  "limitName": null,
  "primary":   { "usedPercent": 4, "windowDurationMins": 10080, "resetsAt": 1785464765 },
  "secondary": null,
  "credits":   { "hasCredits": false, "unlimited": false, "balance": "0" },
  "individualLimit": null,
  "spendControlReached": false,
  "planType": "plus",
  "rateLimitReachedType": null
}
```

- `primary.windowDurationMins = 10080` = **7 日**。これが唯一の枠。
- `secondary = null` — **2 本目の枠は報告されていない**。
- `resetsAt = 1785464765` = 2026-07-31T11:26 JST。

→ **実測を採用する。今の Plus は週次 1 本。**

### 1-2. いつ変わったか — **CONFIRMED(実測)**、切替日は独立に裏が取れた

`~/.codex/sessions/**/*.jsonl` に記録された **2,778 件**の `token_count` イベント（`rate_limits` スナップショット付き、2026-05-03〜07-24）を時系列に並べると、枠の形は**一度だけ**変わっている。

| 期間 | `primary` | `secondary` |
|---|---|---|
| 2026-05-03 〜 **2026-07-12** | 300 分（5 時間） | 10080 分（週次） |
| **2026-07-17** 〜 現在 | 10080 分（週次） | なし |

- 最後に 5 時間枠が観測されたのは `2026-07-12T14:47:11Z`、最初に週次単独が観測されたのは `2026-07-17T11:48:38Z`。この間に実機の利用が無いため、実測だけでは切替日を **07-12〜07-17 の範囲**にしか絞れない。
- 2026-07-17T16:21 に古い形が再出現するが、これは**再開/フォークしたセッションが過去履歴を再生している**もの（同一ミリ秒に 300 分と 10080 分の両方が現れる）。ライブ値ではない。
- **裏取り（SECONDARY のみ）**: OpenAI の VP が 2026-07-12 に X で "Temporarily removing the 5 hour usage limit restriction for all Plus, Business and Pro plans" と投稿している。日付は上の実測レンジの下端とちょうど一致する。**ただし OpenAI のヘルプ / ドキュメント / changelog に対応する記載は無い。**

> **⚠ この撤廃は "Temporarily" と告知されている（二次情報）。5 時間枠が戻る前提で設計すること。** 戻れば「短時間にレビューをまとめて回す」運用が即座に効かなくなる。§6 の非対話読み出しを定期的に叩いて `secondary` の復活を検知するのが唯一の確実な監視手段。

### 1-3. `five-hour-limit` プレースホルダは「無ければ黙って消える」— **CONFIRMED(実測)**

Issue 本文は「`tui.status_line` に `five-hour-limit` / `weekly-limit` が並んでいるので実機の TUI で残量を確認できるはず」を前提にしている。**この前提のうち `five-hour-limit` の側は、今は何も描画しない。**

同梱バイナリの statusline プレースホルダ説明文字列:

```
annual-limit    Remaining usage on the annual usage limit (omitted when unavailable)
monthly-limit   Remaining usage on the monthly usage limit (omitted when unavailable)
weekly-limit    Remaining usage on the weekly usage limit (omitted when unavailable)
daily-limit     Remaining usage on the daily usage limit (omitted when unavailable)
five-hour-limit Remaining usage on the 5-hour usage limit (omitted when unavailable)
```

`~/.codex/config.toml` に `five-hour-limit` を書いてあっても、サーバーが 5 時間窓を返さない現状では**エラーにも警告にもならず、ただ空になる**。**設定ファイルを見て「5 時間枠がある」と判断してはいけない。**

> CLI 側は `annual` / `monthly` / `weekly` / `daily` / `five-hour` の 5 種類を描画できる。**どれが実在するかはサーバーが決める。** なお CLI は窓を**名前ではなく長さで**判定する（300≈5h / 1440≈daily / 10080≈weekly、±5% 許容 — `openai/codex` の `tui/src/chatwidget/rate_limits.rs`）。

### 1-4. モデルごとに分かれるのか — **共通枠 1 本**

**CONFIRMED(実測)。** app-server の応答スキーマ `GetAccountRateLimitsResponse` には

- `rateLimits` — 「Backward-compatible single-bucket view」
- `rateLimitsByLimitId` — 「Multi-bucket view keyed by metered `limit_id` (for example, `codex`)」

の 2 つがある。**実測では `rateLimitsByLimitId` のキーは `codex` の 1 つだけ**で、中身は `rateLimits` と同一。記録済みスナップショット 2,778 件でも `limit_id` は全件 `codex`。使ったモデルは `gpt-5.5` と `gpt-5.6-sol` の 2 種類にまたがるが、枠は分かれていない。

**CONFIRMED(docs) と整合する。** 公式は単一のクレジット・レートカード（§2-1）と単一の窓を示しており、モデル別のメッセージ数はその 1 本の枠を各モデルの credit 単価で割ったものになっている（Sol はトークンあたり Luna のちょうど 5 倍のコストで、メッセージ許容量もちょうど 1/5）。

→ **`gpt-5.6-sol` を使っても `gpt-5.6-terra` を使っても、同じ 1 本の枠を食う。** Claude 側の「共通枠 / Fable 枠の 2 本」に相当する構造は、Codex 側には**無い**。

ただしバイナリには per-model 上限に当たったときの文言が存在する:

```
You've hit your usage limit for {model}. Switch to another model now,
```

プロトコルの `limit_id` にも `codex` / `codex_other` / `codex_secondary` という値域がある。→ **モデル別枠を想定した構造は持っている**。Plus の現状で発火しないだけで、将来分かれる可能性はある（UNKNOWN）。

### 1-5. 枠は Codex 専用ではない — **CONFIRMED(docs)**

`https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan`:

> "Usage from Codex, ChatGPT Work, ChatGPT for Excel, and Workspace Agents draws from the **same agentic usage and credit pool** when those features are available on your plan."

→ **レビューに枠を割く判断は、Codex 以外の agentic 機能とのトレードオフでもある。**

### 1-6. クレジットは枠とは別立て — **CONFIRMED(実測+docs)**

`credits: { hasCredits: false, unlimited: false, balance: "0" }`。従量クレジットは**購入制の別勘定**で、週次枠を使い切ってからの続行手段。

> "ChatGPT Plus and Pro users who reach their usage limit can purchase additional credits to continue working without needing to upgrade their existing plan."（learn.chatgpt.com/docs/pricing）

### 1-7. 「上限リセット券」が 3 枚ある — **CONFIRMED(実測)**

調査中に見つかった想定外の資産。`account/rateLimits/read` の応答:

```json
"rateLimitResetCredits": {
  "availableCount": 3,
  "credits": [
    { "resetType": "codexRateLimits", "status": "available",
      "title": "Full reset",
      "description": "Thanks for using Codex! You've been granted one free rate limit reset.",
      "expiresAt": 1785110521 },
    ...
  ]
}
```

- 3 枚とも `status: "available"`、`title: "Full reset"`。
- **有効期限がある。** 最も早い 1 枚は **2026-07-27T08:23 JST に失効**。残り 2 枚は 2026-07-31 / 2026-08-12 に失効。
- TUI からは `/usage` → 「Redeem usage limit reset」。非対話では `account/rateLimitResetCredit/consume`（**副作用あり**）。

→ **上限に当たっても、リセット券 1 枚で枠が全快する。** 制約 (a) の厳しさを一段緩める材料であり、同時に「使わないと消える」ものでもある。

---

## 2. 消費の主因（Issue 質問 2）

### 2-1. 課金はトークンベース。重みは公表されている — **CONFIRMED(docs)**

`https://help.openai.com/en/articles/20001106-codex-rate-card`:

> "Codex usage is priced based on API token usage, calculated as **credits per million input tokens, cached input tokens, and output tokens**." … "This format replaces average per-message estimates with a direct mapping between token usage and credits."

レートカード（credits / 100 万トークン）:

| モデル | fresh input | cached input | output |
|---|---|---|---|
| **GPT-5.6 Sol** | **125** | **12.5** | **750** |
| GPT-5.6 Terra | 62.5 | 6.25 | 375 |
| GPT-5.6 Luna | 25 | 2.5 | 150 |
| GPT-5.4 mini | 18.75 | 1.875 | 113 |

読み取るべき比:

- **output は fresh input の 6 倍**（トークンあたり）
- **cached input は fresh input の 1/10**
- モデル間はきれいに定数倍（Sol = Terra の 2 倍 = Luna の 5 倍）

> `https://learn.chatgpt.com/docs/pricing`: "Tasks that look similar can consume different amounts of your allowance. Model choice, context, reasoning, tool use, retrieval, and caching all affect usage, so **prompt length alone isn't a reliable estimate**."

### 2-2. 実測: 1% ≒ 200 万トークン ≒ 62 credits — **CONFIRMED(実測)**

`account/usage/read` はサーバー側が持つ**日次トークン集計**を返す（アカウント全体、CLI / デスクトップ / Cloud を問わない完全な値）。これを、記録済みスナップショットから読み取った**週次 % の変化幅**と突き合わせる。

| 週次窓（UTC） | % の観測幅 | サーバー集計トークン | 1% あたり | 100% 換算 |
|---|---|---|---|---|
| 05-08 → 05-15 | 2 → 86 | 226,492,464 | 2,696,339 | 2.70×10⁸ |
| 05-24 → 05-31 | 0 → 31 | 58,100,361 | 1,874,205 | 1.87×10⁸ |
| 06-05 → 06-12 | 1 → 47 | 68,337,836 | 1,485,605 | 1.49×10⁸ |
| 06-12 → 06-19 | 1 → 39 | 75,738,282 | 1,993,113 | 1.99×10⁸ |
| 06-26 → 07-03 | 1 → 21 | 40,041,658 | 2,002,083 | 2.00×10⁸ |
| 07-01 → 07-08 | 1 → 21 | 28,804,919 | 1,440,246 | 1.44×10⁸ |
| **07-17 → 07-24**（新構造） | 0 → 14 | 32,206,147 | 2,300,439 | **2.30×10⁸** |

- 中央値 **1% ≒ 199 万トークン → 週次枠 ≒ 2×10⁸ トークン**。7 窓のばらつきは 1.44〜2.70×10⁸ で **1.9 倍のレンジ**に収まる。
- **5 時間枠が消えた前後で総量は変わっていない**（05-08 週の 2.70×10⁸ と 07-17 週の 2.30×10⁸）。**構造が変わっただけで、週にできる仕事の総量は据え置き。**
- % の観測幅は「記録に残っている範囲」なので真の消費幅より小さい可能性がある。したがって上表の「1% あたり」は**やや過大**に出る。2×10⁸ は上振れ側の見積り。

**レートカードを当てて credits に換算すると**（fresh / cached / output の内訳は生ログから、総量はサーバー集計で補正）:

| 週次窓 | 実測 credits/1% | 100% 換算 |
|---|---|---|
| 05-24 → 05-31 | 77 | 7,750 |
| 06-05 → 06-12 | 45 | 4,452 |
| 06-12 → 06-19 | 65 | 6,507 |
| 06-26 → 07-03 | 54 | 5,391 |
| 07-01 → 07-08 | 36 | 3,608 |
| **07-17 → 07-24**（全て Sol） | **62** | **6,171** |

→ **週次枠 ≒ 6,000 credits（レンジ 3,600〜7,800）** — INFERRED。

**独立した整合性チェック**: 公式は「GPT-5.6 usage averages **5-40 credits per message**」「A typical Codex task using GPT-5.5 may consume between **5-45 credits per task**」と書いている。実測した単発ターンの credits は 15〜85（§4-1）で、**オーダーが合っている**。トークンベースの実測とレートカードという 2 つの独立な経路が同じ答えに収束した。

### 2-3. effort は「出力トークン経由でのみ」効く、しかも効き幅は小さい — **CONFIRMED(実測)**

**公式には effort 別の credit 倍率は公表されていない**（"context, reasoning, and tools" という一般記述のみ）。実測する。

記録済みセッションの `last_token_usage` を model / effort ごとに集計（1 リクエストあたりの平均）:

| model / effort | リクエスト数 | 出力/req | うち reasoning/req | reasoning 比率 | fresh input/req |
|---|---|---|---|---|---|
| gpt-5.5 / medium | 1,484 | 420 | 88 | 20.9% | 13,811 |
| gpt-5.5 / high | 637 | 537 | 159 | 29.5% | 17,366 |
| gpt-5.5 / xhigh | 291 | 829 | 307 | 37.1% | 11,975 |
| gpt-5.6-sol / high | 325 | 512 | 163 | 31.8% | 10,191 |

1. **effort は出力を増やす。** medium → xhigh で出力 **×1.97**、high → xhigh で **×1.54**。reasoning トークンだけなら medium → xhigh で **×3.5**。
2. **effort は入力を増やさない。** fresh input/req は 1.0〜1.7 万で effort と相関しない。
3. **しかし credits に占める出力の割合は小さい。** 実測セッションで出力が占める credit の割合は **8〜22%**（§4-1 の表）。

→ **effort を `high` → `xhigh` に上げたときの消費増は、credits ベースで +5〜10%**（出力 ×1.54 × 出力シェア 10〜22%）。**2 倍にはならない。**

> **UNKNOWN: effort がターン数を増やす間接経路。** 高い effort ほどツールコールを多く回す → 入力を積み増す、という経路は測っていない（タスク難易度が交絡し、記録済みログからは分離できない）。この経路が効くなら影響は上記より大きい。

### 2-4. 別レバー: Fast mode は素直に高い — **CONFIRMED(docs)**

`https://learn.chatgpt.com/docs/agent-configuration/speed`:

> "Speed configurations increase credit consumption for all applicable models, so they also use included limits faster. **Fast mode consumes credits at a higher rate** for supported models."（速度は 1.5 倍）

また画像生成は "use[s] included limits **3-5x faster** on average"。

### 2-5. 実務的な含意

Claude 側（#7）で確立した「**effort はモデルより安いレバー**」は Codex 側でも成り立つ。むしろ**より強く**成り立つ — 消費が入力支配なので、`model_reasoning_effort` を `high` → `xhigh` に上げても週次枠への影響は +5〜10% に留まる。

**枠を守りたいなら、削るべきは effort ではない。効くのは順に:**

1. **モデル帯**（Sol → Terra で単価ちょうど 1/2、→ Luna で 1/5）
2. **1 回に渡す diff とコンテキストの大きさ**（fresh input が支配）
3. **セッションを引きずらないこと**（cached input はターンを重ねるごとに二次的に積み上がる。19 ターンのセッションが週次枠の 8.4% を食っている — §4-1）
4. effort（+5〜10%）

---

## 3. 超過時の挙動（Issue 質問 3）

### 3-1. ハードストップ。ただし進行中のターンは完走させる — **CONFIRMED(docs+実測)**

`https://learn.chatgpt.com/docs/pricing`:

> "We want you to be able to complete work already in progress. **If you reach your usage limits during an active turn, the agent will be able to continue working on that turn**, subject to fair use limits."

`https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan`:

> "If you reach a usage limit during an active turn, Codex can continue working on that turn... After that turn, check the Codex usage page or the limit banner for the options available on your plan, such as adding credits, applying an available reset, upgrading, or waiting for the limit to reset."

ソースレベルでも確定している（`openai/codex`）:

- `codex-api/src/api_bridge.rs` — `error.type == "usage_limit_reached"` の 429 は `CodexErr::UsageLimitReached` になる（それ以外の 429 は `RetryLimit`）
- `protocol/src/error.rs` — `UsageLimitReached` は **`is_retryable() == false`** 側
- `core/src/session/turn.rs` — スナップショットを記録して即 `return Err(err)`
- 全エンドポイントが `retry_429: false`

同梱バイナリ 0.145.0 のプラン別文言も一致する:

| プラン | 文言 |
|---|---|
| Free | `You've hit your usage limit. Upgrade to Plus to continue using Codex (…)` |
| **Plus** | **`You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits`** |
| Business/Enterprise メンバー | `You've hit your usage limit. To get more access now, send a request to your admin` |
| per-model 上限 | `You've hit your usage limit for {model}. Switch to another model now,` |

**いずれも「止まる」文言。「勝手に下位モデルへ切り替えた」旨の文言は存在しない。**

### 3-2. サイレントフォールバックは存在しない — **CONFIRMED(negative)**

モデル切替の機構は**対話式・opt-in・上限到達前**のものが 1 つあるだけ（`tui/src/chatwidget/rate_limits.rs`）:

```rust
pub(super) const NUDGE_MODEL_SLUG: &str = "gpt-5.6-luna";
pub(super) const RATE_LIMIT_SWITCH_PROMPT_THRESHOLD: f64 = 90.0;
```

バイナリ内の対応する UI 文字列:

```
Approaching rate limits
Uses fewer credits for upcoming turns.
Keep current model
Keep current model (never show again)
```

- **90% で 3 択ポップアップ**を出す。既定は「現在のモデルを維持」。承諾しなければ切り替わらない。
- **`codex exec` にはこのポップアップが無い**（非対話警告は 75 / 90 / 95% で出る）。
- 公式も同じことを「助言」として書いている: "If you are approaching usage limits, **you can also switch** to a smaller model to make your usage limits last longer."

**紛らわしいが無関係なもの**（実測で除外済み）:

- `model/rerouted` 通知（`ModelReroutedNotification`）— 用途は**モデルの廃止**（`GPT-5.4 is no longer available / Codex now uses GPT-5.6 Terra…`）と **safety buffering**（`Our systems are thinking a bit more about this request… Hang tight or retry with a faster model` — これもユーザーが選ぶ）。レート制限とは無関係。
- `compact_model_fallback.rs`（コンパクションのリトライ）、`client.rs` の fallback（WebSocket→HTTP のトランスポート退避）。

→ **レート制限を理由にモデルが自動で降格される経路は存在しない。**

### 3-3. これは UNKNOWN のままにできるか — **できない。そして UNKNOWN でもない**

Issue はこの点を「UNKNOWN のままにできるか自体を判定すること」と書いている。判定結果:

- **前マップ（#11）で Fable の 50% キャップを UNKNOWN のまま通せたのは、「停止でも silent fallback でも取るべき行動が同一」だったから**であって、情報が要らなかったからではない。
- **今回は同一ではない。** サイレントフォールバックがあるなら「レビューは常に走るが、枠が尽きた後は品質が黙って落ちる」— これは**レビューを独立レビュアとして信頼する前提そのものを壊す**（#13 の「レビュアは実装者と別モデル」という原理が、黙って別の弱いモデルに置き換わることで無効化される）。ハードストップなら「レビューが走らなかったこと」は必ず可視化される。**設計上の意味が正反対**なので UNKNOWN では通せない。
- **そして UNKNOWN にする必要がない。ハードストップだと docs・ソース・バイナリの 3 つで確定した。**

→ **設計上の要件は 1 つだけ: 非対話実行の終了コードとエラー文言を握りつぶさないこと。** 失敗は必ず見える形で出るので、それ以上のガードは要らない。

---

## 4. 中規模 PR レビュー 1 回のオーダー感（Issue 質問 4）

### 4-1. 実測された単発ターンの消費 — **CONFIRMED(実測)**

`codex review` を実際に走らせるとクォータを消費するので**走らせていない**。代わりに、記録済みセッションのうち**ターン数が少なく単発の作業に近いもの**を実測値として使う。credits は Sol のレートカードで換算、% は週次枠 6,171 credits に対する比。

| セッション | ターン | 総トークン | fresh in | 出力 | **credits** | 出力シェア | **週次枠の** |
|---|---|---|---|---|---|---|---|
| 2026-07-24T14:55 | 1 | 315,253 | 83,966 | 2,423 | 15.2 | 12.0% | **0.25%** |
| 2026-07-25T05:24 | 1 | 1,167,220 | 107,760 | 9,860 | 34.0 | 21.8% | **0.55%** |
| 2026-07-17T20:49:25 | 3 | 1,237,726 | 151,302 | 6,104 | 37.0 | 12.4% | **0.60%** |
| 2026-07-17T20:49:01 | 3 | 1,809,389 | 157,975 | 12,502 | 49.6 | 18.9% | **0.80%** |
| 2026-07-17T20:48:10 | 1 | 3,889,742 | 241,037 | 10,945 | 83.8 | 9.8% | **1.36%** |
| 2026-07-18T01:21 | 9 | 8,407,049 | 1,138,290 | 56,343 | 274.7 | 15.4% | 4.45% |
| 2026-07-10T18:25 | 19 | 19,039,444 | 1,884,111 | 89,221 | 515.8 | 13.0% | 8.36% |

**独立した裏取り**: 2026-07-17T11:48〜11:57 に上位 3 セッションを**並列で回した 9 分間**で、週次枠は **0% → 6%** に動いた。3 セッション合計 6.94×10⁶ トークン ÷ 6 ポイント = 1.16×10⁶ トークン/% — §2-2 の 2×10⁶ と同じオーダー。

### 4-2. レビュー 1 回 ≒ 30〜85 credits ≒ 週次枠の 0.5〜1.5% — **INFERRED**

- `codex review --base <branch>` は「差分を読む → 関連ファイルを追う → 指摘を書く」の単発エージェントターン。上表の 1〜3 ターン帯（0.25〜1.36%）に相当し、中規模 PR ならその上寄り。
- **公式の "5-40 credits per message" / "5-45 credits per task" と整合する。**
- **これは実測ではない。** 反証したければ §4-4。

> **重要な scoping（CONFIRMED(docs)）**: `https://learn.chatgpt.com/docs/pricing` は "Code Review usage applies only when Codex runs reviews **through GitHub**… Reviews run **locally** or outside of GitHub count [as local messages]" と書いている。つまり **`codex review` / `codex exec review` をローカルで回す限り、通常のローカルメッセージ枠を食う**（= 上の計算がそのまま当てはまる）。GitHub 経由の `@codex review` は別カラムだが、そのカラムは Plus・Pro 20x を含む**全プランで "Not available" と表示されている**（未公表なのか本当に不可なのかは UNKNOWN）。

### 4-3. 受け入れ基準への答え

| 1 日のレビュー回数 | 週次枠の消費 | 判定 |
|---|---|---|
| 1 回 | 3.5〜10% | 余裕 |
| **5 回** | 18〜53% | **安全**（他の Codex 利用と併用できる） |
| **10 回** | 35〜105% | **レビュー主体なら成立。対話利用と併用するとギリギリ** |
| 30 回 | 105〜315% | 破綻 |
| 100 回 | 350〜1050% | **確実に破綻** |

> **桁の答え: 1 日 10 回オーダーは成立する。100 回オーダーは成立しない。**
> Codex を対話でも使う前提なら、レビューに回せるのは **1 日 5〜10 回**が現実的な線。

### 4-4. 決着させる実験（**クォータを消費する**）

やるなら:

1. `account/rateLimits/read` で `usedPercent` を記録（§6、消費ゼロ）
2. `codex review --base main` を **5 回連続**で実行 — **1 回だと整数丸めで読めない**（1% 未満の変化は `usedPercent` が int32 なので見えない）
3. 再度 `account/rateLimits/read`、差分 ÷ 5

- **見積りコスト: 週次枠の 3〜8%**。
- リセット券が 3 枚あり、うち 1 枚は **2026-07-27 に失効**する（§1-7）。**失効させるくらいなら、この実験に使って券で全快させるほうが得。**

---

## 5. Plus と Pro の差（Issue 質問 5）— **CONFIRMED(docs)**

`https://learn.chatgpt.com/docs/pricing`:

> "Choose **5x or 20x** higher rate limits than Plus."
> "**5x or 20x** more Codex usage than Plus*"

公表値（ローカルメッセージ / 5 時間）:

| モデル | Plus | Pro 5x（$100/月） | Pro 20x（$200/月） |
|---|---|---|---|
| GPT-5.6 Sol | 15〜90 | 75〜450 | 300〜1800 |
| GPT-5.6 Terra | 20〜110 | 100〜550 | 400〜2200 |
| GPT-5.6 Luna | 50〜280 | 250〜1400 | 1000〜5600 |
| GPT-5.5 | 15〜80 | 75〜400 | 300〜1600 |

**全行でちょうど 5 倍 / 20 倍**。倍率に例外は無い。

| プラン | Plus 比 |
|---|---|
| **Business** | **Plus と完全同一**（シート単位。テーブルがバイト単位で一致） |
| Enterprise / Edu（flexible pricing あり） | 固定上限なし。クレジットに応じてスケール |
| Enterprise / Edu（flexible pricing なし） | ほとんどの機能で Plus と同一（シート単位） |
| Team | 現行ページに独立した段として存在しない |

**判断材料としての含意**: 「1 日 10 回」の壁は Pro 5x で **1 日 50 回**、Pro 20x で **1 日 200 回**になる。ただし **§1-1 の 5 時間枠テーブルは現状の実機と一致していない**ので、この倍率が「週次枠にもそのまま 5x / 20x で効く」かは UNKNOWN（倍率が枠の種類に依らないと仮定すれば効くはず — INFERRED）。

---

## 6. 非対話で残量を読む方法 — **見つかった** CONFIRMED(実測+docs)

Issue の「非対話で読む手段はあるか」への答え: **ある。app-server の JSON-RPC。しかも消費ゼロ。**

まず**無い**もの（`openai/codex` のソースで確認）:

- `codex usage` サブコマンドは**存在しない**（`cli/src/main.rs` のサブコマンド一覧に無い。ローカルの `codex --help` とも一致）
- `codex exec --json` は `thread.*` / `turn.*` / `item.*` / `error` しか出さない。`TurnCompletedEvent { usage }` はトークン数だけで **`rate_limits` を含まない**
- TypeScript SDK に rate limit 関連の API は**ゼロ**
- `docs/*.md` 全 15 本に "rate limit" / "usage limit" の記載は**ゼロ**

### 6-1. 手順

`codex app-server` は stdio 上の JSON-RPC サーバー。プロトコル定義は `app-server-protocol/src/protocol/common.rs`:

```rust
GetAccountRateLimits => "account/rateLimits/read" { … response: v2::GetAccountRateLimitsResponse }
GetAccountTokenUsage => "account/usage/read"      { … }
AccountRateLimitsUpdated => "account/rateLimits/updated"   // push 通知
```

流し込む JSON（`initialize` → `initialized` → 目的のリクエスト）:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"probe","version":"0.0.1"}}}
{"jsonrpc":"2.0","method":"initialized"}
{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}
{"jsonrpc":"2.0","id":3,"method":"account/usage/read","params":null}
```

**実測でつまずいた点:**

- **`initialize` の応答を待ってから `initialized` を送る。** 4 行を一括で流し込むと後続リクエストが黙って無視される。
- **stdin を開いたまま数秒待つ。** EOF で即終了する。
- `params` は `null` を**明示**する。
- ハンドラ（`app-server/src/request_processors/account_processor.rs`）は `/api/codex/usage` を**都度叩く**（キャッシュしない）。ChatGPT 認証が必要。
- **モデル推論は走らない。クォータを消費しない。**

### 6-2. 取れるもの

| メソッド | 返るもの |
|---|---|
| `account/rateLimits/read` | `usedPercent` / `windowDurationMins` / `resetsAt` / `planType` / `credits` / `rateLimitsByLimitId` / **リセット券の在庫と有効期限** |
| `account/usage/read` | `lifetimeTokens` / `peakDailyTokens` / `longestRunningTurnSec` / 連続利用日数 / **日次トークン集計（60 日分）** |
| `account/rateLimitResetCredit/consume` | リセット券の消費（**副作用あり**。読み取りではない） |

`codex app-server generate-json-schema --out <DIR>` でプロトコルの JSON Schema 一式が落ちる（`v2/GetAccountRateLimitsResponse.json` 等）。これも消費ゼロ。

> **命名規則の罠**: app-server のワイヤ上は **camelCase**（`usedPercent` / `windowDurationMins`）、生ログの中は **snake_case**（`used_percent` / `window_minutes`）。同じ構造体だが表記が違う。

### 6-3. 他に試して駄目だったもの — CONFIRMED(実測)

| 手段 | 結果 |
|---|---|
| `codex doctor` | 認証状態・到達性は出るが**残量は出ない** |
| `~/.codex/.codex-global-state.json` | Electron アプリの UI 状態のみ。**残量は入っていない**（`rate-limit-reset-home-announcement-dismissal-by-account-id` は「お知らせを閉じたか」の記録だけ） |
| `~/.codex/models_cache.json` | モデルカタログ。**消費倍率は入っていない**（`multiplier` / `cost` / `credit` 相当のキーが存在しない） |
| `codex debug models` / `codex debug prompt-input` | 残量を扱わない |

### 6-4. 過去の残量は生ログに残っている — **本調査の土台**

`rollout/src/policy.rs` の `should_persist_event_msg` に `EventMsg::TokenCount(_) => true` があるため、**毎リクエストの rate-limit スナップショットがセッションの rollout JSONL に追記される**:

```json
{"type":"event_msg","payload":{"type":"token_count","info":{...},
 "rate_limits":{"limit_id":"codex","primary":{"used_percent":4,"window_minutes":10080,"resets_at":...},
                "secondary":null,"credits":{...},"plan_type":"plus","rate_limit_reached_type":null}}}
```

- 置き場所: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
- 最新のものは `~/.codex/state_5.sqlite` の `threads(rollout_path, updated_at)` から引ける
- TUI は **15 分より古いスナップショットを stale 扱い**する（`RATE_LIMIT_STALE_THRESHOLD_MINUTES`）。無料だが鮮度は保証されない

**本調査の §1-2 / §2-2 / §2-3 / §4-1 はすべてこのログから導いている。** 過去に遡った再検証が可能。

---

## 7. Issue #17 の前提のうち、訂正が必要なもの

| Issue 本文の記述 | 実測 |
|---|---|
| 「5 時間枠 / 週次枠のそれぞれの存在」を前提にしている | **5 時間枠は 2026-07-12 頃に消えた。** 今あるのは週次 1 本。**ただし "Temporarily" と告知されており、戻る前提で設計すべき** |
| 「`tui.status_line` に両方並んでいるので実機の TUI で残量を確認できる」 | `weekly-limit` は出る。`five-hour-limit` は**黙って空になる**（設定は残っていても発火しない） |
| 「実測するならレビューを 1 回走らせて前後の残量を比較」 | 1 回では**整数丸めで読めない**（消費が 1% 未満）。最低 5 回必要 |
| 「モデルごとに枠が分かれるのか共通か」 | **共通（`limit_id = "codex"` 1 本）**。ただしプロトコルはモデル別枠を表現できる |
| 「reasoning effort が消費に効くのか」 | 効くが**小さい**。high→xhigh で **+5〜10%**。効くのは入力量とモデル帯 |

## 8. 追加で分かった、判断に効きそうなこと

- **リセット券が 3 枚眠っており、最短で 2026-07-27 に 1 枚失効する**（§1-7）。制約 (a) に当たっても即座に全快できる手札が存在する。
- **5 時間枠の消滅は運用に効くが、当てにしてはいけない。** 旧構造では「短時間に集中してレビューを回すとバースト制約に当たる」があった。今は無い。**が "Temporarily" 告知（二次情報のみ）なので、戻ったときに壊れない設計にしておくこと。**
- **枠は Codex 専用ではない**（§1-5）。ChatGPT Work / Excel / Workspace Agents と同じプールを食う。
- **モデル帯が最も効くレバー**（§2-5）。Sol → Terra で単価ちょうど半分。**レビュー用途で Sol が必要かは別途検討の価値がある**（#16 の起動経路の議論に接続する）。
- **セッションを引きずるコストが大きい。** cached input は単価 1/10 だが量が桁違いに積み上がる。19 ターンのセッションが週次枠の 8.4% を食っている。**レビューは 1 発ずつ使い捨てで回すのが構造的に正しい。**

---

## 9. UNKNOWN 一覧（推測で埋めていないもの）

| 項目 | なぜ不明か | 決着させる方法 |
|---|---|---|
| 5 時間枠撤廃の公式な裏付けと恒久性 | 一次情報が存在しない（OpenAI VP の X 投稿のみ）。公式ドキュメントは今も 5 時間枠を記載 | §6 を定期的に叩いて `secondary` の復活を監視するしかない |
| 5 時間枠が消えた正確な日 | 2026-07-12〜07-17 に実機の利用が無い | 同上。二次情報は 07-12 と言っている |
| effort がターン数を増やす間接経路 | タスク難易度が交絡し、記録済みログから分離できない | 同一タスクを effort だけ変えて 2 回。クォータ消費 |
| `codex review` 1 回の実測値 | 走らせるとクォータを消費するため未実行 | §4-4 の手順。週次枠 3〜8% |
| 非対話実行が上限に当たったときの終了コード | 上限に当てないと確認できない | 枠を使い切った状態で `codex exec` を 1 回 |
| GitHub 経由の Code Review 枠 | 公式テーブルが**全プランで "Not available"** と表示する（Pro 20x を含む） | 実際に `@codex review` を 1 回打つ。ローカル経路とは別勘定 |
| Plus→Pro の 5x/20x が週次枠にも効くか | 公表テーブルが 5 時間枠ベースで、その 5 時間枠が現状存在しない | Pro 契約者の `account/rateLimits/read` を見る以外に手段が無い |
| per-model 枠が Plus で将来発火するか | 現状 `limit_id` は `codex` のみ | `rateLimitsByLimitId` を定期観測 |
| GPT-5.5 のレートカード | 公式レートカードに GPT-5.6 系と 5.4-mini しか無い | — |
