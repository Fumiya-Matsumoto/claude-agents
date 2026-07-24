# モデル / effort の指定可能値とエイリアス解決（2026-07-25 時点）

- 対象 Issue: [#4](https://github.com/Fumiya-Matsumoto/claude-agents/issues/4)（Part of #3）
- 調査日: 2026-07-25
- 調査時のローカル環境: `claude --version` = **2.1.219 (Claude Code)**
- 一次情報のみ使用。記憶ベースの記述は排除している。

## 一次情報ソース

| # | ソース | URL / 参照 |
|---|---|---|
| S1 | Claude Code Docs — Create custom subagents | https://code.claude.com/docs/en/sub-agents |
| S2 | Claude Code Docs — Model configuration | https://code.claude.com/docs/en/model-config |
| S3 | Claude Platform Docs — What's new in Claude Opus 5 | https://platform.claude.com/docs/en/about-claude/models/whats-new-opus-5 |
| S4 | 同梱スキル `claude-api`（`shared/models.md` / `shared/model-migration.md` / SKILL.md） | ローカル bundled skill（本リポジトリ外、Claude Code 同梱） |
| S5 | ローカル実行環境の実測 | `claude --version` の出力、および実行中セッションのモデル ID 表示 |

> **鮮度について**: S1–S3 はいずれも Opus 5 リリース（2026-07-24）後の記述を含んでおり（S2 に `min-version: 2.1.219` 注記、S3 が Opus 5 専用ページ）、本日時点で最新と判断できる。S4 のモデル表は skill 内に `cached: 2026-06-24` と明記があり **Opus 5 リリース前のキャッシュ**だが、本文（SKILL.md / models.md / model-migration.md）自体には `claude-opus-5` の項目が存在するため、Opus 5 に関する記述は反映済み。S4 単独に依拠した箇所は本文中で明示する。

---

## Q1. `model:` に指定できる値

**CONFIRMED（S1）**

S1「Supported frontmatter fields」表より逐語引用:

> | `model` | No | [Model](#choose-a-model) to use: `sonnet`, `opus`, `haiku`, `fable`, a full model ID (for example, `claude-opus-5`), or `inherit`. Defaults to `inherit` |

同 S1「Choose a model」節:

> * **Model alias**: use one of the available aliases: `sonnet`, `opus`, `haiku`, or `fable`
> * **Full model ID**: use a full model ID such as `claude-opus-5` or `claude-sonnet-5`. Accepts the same values as the `--model` flag
> * **inherit**: use the same model as the main conversation
> * **Omitted**: defaults to `inherit` and uses the same model as the main conversation

結論:

- エイリアスの集合は **`sonnet` / `opus` / `haiku` / `fable` の 4 つ**。frontmatter の `model` に関してはこれが全部（**CONFIRMED**）。
- **明示的なモデル ID も使える**（例: `claude-opus-5`）。「Accepts the same values as the `--model` flag」（**CONFIRMED**）。
- **`inherit` も有効値**で、かつ **省略時のデフォルトが `inherit`**（**CONFIRMED**）。← ここは Issue の選択肢に無かった第 5 の値。

補足（**CONFIRMED**、S2）: セッションレベルのエイリアスには `default` / `best` / `opusplan` / `sonnet[1m]` / `opus[1m]` も存在するが、S1 の frontmatter 表・「Choose a model」節はこれらを列挙していない。frontmatter で使えるかは **UNKNOWN**（Q5 の後半参照）。

補足（**CONFIRMED**、S2）: Anthropic API 上では Claude Code が受け付ける文字列は「a model alias / an entry from the `/model` picker / any name that starts with `claude-` / custom model option or `modelOverrides`」。未知文字列は `Model "<name>" is not a recognized model id.` で拒否される。ただしこのチェックは `--model` フラグ・`ANTHROPIC_MODEL`・`model` 設定には掛からない。一方 S2 は「The check also covers a `model` set in [subagent frontmatter]」と明記しており、**frontmatter の `model` は retirement / remap 警告の対象**である（**CONFIRMED**）。

### 解決の優先順位（**CONFIRMED**、S2）

> 1. The [`CLAUDE_CODE_SUBAGENT_MODEL`] environment variable, when set to a model alias or model ID
> 2. The per-invocation `model` parameter
> 3. The subagent definition's `model` frontmatter
> 4. The main conversation's model

つまり **frontmatter の `model` は環境変数と呼び出し時パラメータに上書きされる**。加えて組織の `availableModels` 許可リストに弾かれた値はスキップされ、inherit にフォールバックする（**CONFIRMED**、S2）。

---

## Q2. `opus` / `fable` / `sonnet` は今どのモデルに解決されるか

**CONFIRMED（S2）** — S2「Model aliases」の逐語引用:

> | **`best`** | Uses Fable 5 where your organization has access to it, otherwise the latest Opus model |
> | **`fable`** | Uses Claude Fable 5 for your hardest and longest-running tasks |
> | **`sonnet`** | Uses the latest Sonnet model for daily coding tasks |
> | **`opus`** | Uses the latest Opus model for complex reasoning tasks |
> | **`haiku`** | Uses the fast and efficient Haiku model for simple tasks |

プロバイダ別の解決先（S2 逐語引用）:

> | Provider | `opus` | `sonnet` |
> | Anthropic API | Opus 5 | Sonnet 5 |
> | Claude Platform on AWS | Opus 5 | Sonnet 4.6 |
> | Amazon Bedrock, Google Cloud's Agent Platform | Opus 5 | Sonnet 4.5 |
> | Microsoft Foundry | Opus 4.6 | Sonnet 4.5 |

### ⭐ 最重要: `opus` エイリアスは Opus 5 に移動した

**CONFIRMED（S2）** — バージョン注記の逐語引用:

> {/* min-version: 2.1.219 */}Before v2.1.219, `opus` resolved to Opus 4.8 on the Anthropic API from v2.1.154, and on Claude Platform on AWS, Amazon Bedrock, and Google Cloud's Agent Platform from v2.1.207.

および:

> Opus 5 requires Claude Code v2.1.219 or later.

**ローカル環境は 2.1.219（S5 実測）なので、条件を満たしている。**

したがって本リポジトリの `model: opus` 指定エージェント（`agents/deep-worker.md`, `agents/quality-reviewer.md`）は、**ファイル無変更のまま Opus 4.8 → Opus 5 に昇格済み**（Anthropic API 利用時）。これが Issue の言う「無変更で昇格済み」の裏取りである。

- 判定: **CONFIRMED**（ドキュメントの解決表 + バージョン注記 + ローカルバージョン実測の 3 点で確定）
- 注意（**CONFIRMED**）: Microsoft Foundry 利用時のみ `opus` は依然 Opus 4.6。プロバイダ依存なので「常に Opus 5」ではない。
- 注意（**CONFIRMED**、S2）: エイリアスは時間とともに動く（"Aliases point to the recommended version for your provider and update over time"）。バージョンを固定したいなら `claude-opus-5` のようなフルモデル名を書くか `ANTHROPIC_DEFAULT_OPUS_MODEL` を設定する。**エイリアス運用は「自動追随」と引き換えに「暗黙のモデル変更」を受け入れる設計判断**である。

`sonnet` → Sonnet 5（Anthropic API、**CONFIRMED**）。`fable` → Claude Fable 5（**CONFIRMED**）。

---

## Q3. `fable` は今も存在するか / Opus 5 との上下関係

**CONFIRMED（S2, S3）**

- **存在する**。S2 に `fable` エイリアスの行があり、専用節「Work with Fable 5」も現存:
  > [Claude Fable 5] is the most capable model in Claude Code, suited to tasks larger than a single sitting.
- **上下関係: Fable 5 が上、Opus 5 が下。Opus 5 に superseded されていない。**
  - S2 `best` エイリアス: 「Uses Fable 5 where your organization has access to it, **otherwise the latest Opus model**」→ Fable が第一選択、Opus はフォールバック。
  - S3（Opus 5 ページ）: 「it delivers **frontier intelligence at half the cost of Claude Fable 5**」→ Fable 5 が上位、Opus 5 が価格性能側。
  - S4（`claude-api` skill, `shared/models.md`）も同旨: Claude Fable 5 = "Anthropic's most capable widely released model"、Opus 5 = "comes close to the frontier intelligence of Claude Fable 5 at half the price"。
- 価格（**CONFIRMED**、S3 / S4）: Opus 5 = $5 / $25 per MTok。Fable 5 = $10 / $50 per MTok（S4 の料金表による。S3 は Opus 5 の価格のみ記載）。

Fable 5 固有の制約（**CONFIRMED**、S2）:

- デフォルトモデルではない。`/model fable` で明示選択。
- Claude Code **v2.1.170 以降**が必要。
- **zero data retention 下では利用不可**（`/model` ピッカーに出ないか disabled）。
- 安全分類器が反応した要求は automatic model fallback が発動する。
- **thinking を無効化できない**（`MAX_THINKING_TOKENS=0` などが効かない）。
- Anthropic API では、サーバが組織に対して利用可能と報告するまでピッカーに出ない。

→ 本リポジトリの `model: fable` エージェント 3 つ（frontier-orchestrator / frontier-reviewer / frontier-solver）は、**組織アクセスと ZDR 設定に依存して起動しない可能性がある**という運用上の注意点がある（**CONFIRMED** から導かれる **INFERRED** な運用示唆）。

---

## Q4. `effort:` の指定可能値と、frontmatter で効くか

### 4-a. 指定可能値

**CONFIRMED（S1）** — frontmatter 表の逐語引用:

> | `effort` | No | Effort level when this subagent is active. Overrides the session effort level. Default: inherits from session. Options: `low`, `medium`, `high`, `xhigh`, `max`; available levels depend on the model |

→ Issue が挙げた 5 値（`low` / `medium` / `high` / `xhigh` / `max`）で**過不足なく正しい**。

**CONFIRMED（S2）**: `ultracode` は effort レベルではなく Claude Code の設定であり、`/effort` メニューと `--effort` フラグ、`--settings`／Agent SDK でのみ指定できる。永続 `effortLevel` 設定と `CLAUDE_CODE_EFFORT_LEVEL` は受け付けない。**frontmatter で `ultracode` が使えるとはどこにも書かれていない** → frontmatter での可否は **UNKNOWN**（S1 の options 列挙に含まれないので、使えないと読むのが自然だが明言はない）。

### 4-b. frontmatter で実際に効くか

**CONFIRMED（S1 + S2）** — 二重に明記されている。

S1: 「Effort level when this subagent is active. **Overrides the session effort level.** Default: inherits from session.」

S2「Set the effort level」節:

> * **Skill and subagent frontmatter**: set `effort` in a [skill] or [subagent] markdown file to override the effort level when that skill or subagent runs

および優先順位（S2 逐語）:

> The environment variable takes precedence over all other methods, then your configured level, then the model default. **Frontmatter effort applies when that skill or subagent is active, overriding the session level but not the environment variable.**

→ 実効優先順位: `CLAUDE_CODE_EFFORT_LEVEL`（環境変数） > **frontmatter `effort`** > セッション設定 > モデルデフォルト。**CONFIRMED**。

### 4-c. モデルごとの差

**CONFIRMED（S2）** — 逐語引用:

> | Model | Levels |
> | Fable 5 | `low`, `medium`, `high`, `xhigh`, `max` |
> | Opus 5, Sonnet 5, Opus 4.8, and Opus 4.7 | `low`, `medium`, `high`, `xhigh`, `max` |
> | Opus 4.6 and Sonnet 4.6 | `low`, `medium`, `high`, `max` |
>
> The available effort levels depend on the model. **Models not listed here do not support effort.**

差分の要点:

- **`xhigh` は Opus 4.6 / Sonnet 4.6 に存在しない**（Opus 4.7 で追加）。
- **表に載っていないモデル（Haiku 4.5 など）は effort 非対応。** → 本リポジトリに `model: haiku` のエージェントは現状無いが、将来 haiku を使う際に `effort` を書いても無視される点に注意（**CONFIRMED** から導かれる **INFERRED** な運用示唆）。
- 未サポート値を指定した場合はエラーではなく**サイレントに丸められる**: 「If you set a level the active model does not support, Claude Code falls back to the highest supported level at or below the one you set. For example, `xhigh` runs as `high` on Opus 4.6.」（**CONFIRMED**）
- デフォルト effort は「Opus 4.7 を除く全モデルで `high`」（Opus 4.7 のみ `xhigh`）。**CONFIRMED**。
- Opus 5 固有（**CONFIRMED**、S2）: 「Opus 5 has no such hold: a level you previously set carries over.」← Fable 5 / Opus 4.8 / Opus 4.7 のような「初回起動時にモデルデフォルト effort を強制保持する」挙動が **Opus 5 には無い**。
- `max` はセッション限定で、対話セッションでの設定は永続しない（環境変数経由を除く）。**CONFIRMED**、S2。ただしこれは**セッション設定の話**であり、frontmatter の `effort: max` に同じ制約が掛かるかは明記が無い → **UNKNOWN**。
- 組織（Enterprise）が effort 上限をモデル単位で設定でき、超過指定は上限に丸められる。**CONFIRMED**、S2。

### 4-d. API 側の裏取り（S4）

`claude-api` skill の Thinking & Effort 表も同じ結論を支持する（**CONFIRMED**、S4）: effort は GA（beta header 不要）、`output_config: {effort: ...}` に入れる、Opus 5 は `low`–`max` の全 5 段階、Opus 4.6 / Sonnet 4.6 は `xhigh` 無し。**S1/S2（Claude Code 側）と S4（API 側）が一致している**ため、frontmatter の値がそのまま API の `output_config.effort` に流れていると読める（**INFERRED** — 「frontmatter → API パラメータ」のマッピングを明記した一次情報は見つかっていない）。

---

## Q5. Opus 5 の 1M context はエイリアスで使えるか

**CONFIRMED（S3）** — Opus 5 ページの逐語引用:

> Claude Opus 5 has a [1M token context window] (**1M tokens is both the default and the maximum; there is no smaller context variant**), 128k max output tokens, and thinking on by default.

**CONFIRMED（S2）** — Claude Code 側の記述:

> Availability varies by model and plan. **On the Anthropic API, Fable 5, Sonnet 5, and Opus 4.7 and later always run with the 1M window.**

Opus 5 は「Opus 4.7 and later」に含まれる。

→ **結論: Anthropic API 利用時、素の `opus` エイリアス（= Opus 5）で 1M context が使える。別モデル ID も `[1m]` サフィックスも不要。CONFIRMED。**

### ただし残る不確実性（誠実に列挙）

1. **`opus[1m]` エイリアスの行に「Opus 5 では無意味」の注記が無い。**
   S2 は `sonnet[1m]` について「No effect when `sonnet` already resolves to Sonnet 5 with its native 1M window」と明記しているが、`opus[1m]` の行には対応する注記が無い:
   > | **`opus[1m]`** | Uses Opus with a 1 million token context window for long sessions |

   Sonnet 5 には専用節「Sonnet 5 context window」（「There is no 200K variant, no `[1m]` suffix to select」）があるのに、**Opus 5 に対応する節はドキュメント上にまだ無い**。ドキュメント側が Opus 5 リリースに追随しきれていない可能性がある。→ 「`opus[1m]` が Opus 5 でも no-op である」ことは **INFERRED**（S3 の「no smaller context variant」から論理的に導かれるが、Claude Code ドキュメントの直接の明言は **見つからなかった**）。

2. **サブスクリプションプラン別の表は Opus 5 以前の記述に見える。**
   S2 の表は「Opus with 1M context」を Max/Team/Enterprise = 「Included with subscription」、Pro = 「Requires usage credits」、API and pay-as-you-go = 「Full access」としている。Opus 5 に「smaller context variant が存在しない」（S3）ことと、この Pro 行の「usage credits が要る」がどう両立するかは、**一次情報からは判定できない → UNKNOWN**。API / pay-as-you-go 利用なら影響なし。

3. **frontmatter の `model:` に `[1m]` サフィックスが書けるかは未文書化。**
   S2 は `[1m]` の用例として `/model opus[1m]`、`/model claude-opus-4-8[1m]`、`ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-8[1m]'` を挙げるが、**サブエージェント frontmatter の例は無い**。S1 の frontmatter 表も `[1m]` に言及しない。→ **UNKNOWN**。Opus 5 では不要なので実務上は問題にならない。

4. **観測データ（S5）**: 本調査を実行しているセッション自身のモデル ID は `claude-opus-5[1m]` と報告されている。少なくとも `[1m]` サフィックスは Opus 5 に対しても**受理される**（拒否されない）ことは実測から言える。ただしこれが「意味を持つ」のか「no-op として黙って受け入れられている」のかは、この観測だけでは**判別できない → UNKNOWN**。

5. **`CLAUDE_CODE_DISABLE_1M_CONTEXT=1`**（**CONFIRMED**、S2）を設定している環境では 1M variant がピッカーから外れる。Opus 5 にどう作用するかは未文書 → **UNKNOWN**。

---

## 本リポジトリへの含意

現状の割り当て（2026-07-25 時点、Anthropic API + Claude Code 2.1.219 前提）:

| エージェント | `model:` | 解決先 | `effort:` | 有効か |
|---|---|---|---|---|
| auto-router | `sonnet` | Sonnet 5 | `high` | ✅（Sonnet 5 は 5 段階すべて対応） |
| orchestrator | `sonnet` | Sonnet 5 | `high` | ✅ |
| routine-worker | `sonnet` | Sonnet 5 | `high` | ✅ |
| code-explorer | `sonnet` | Sonnet 5 | `medium` | ✅ |
| test-runner | `sonnet` | Sonnet 5 | `medium` | ✅ |
| deep-worker | `opus` | **Opus 5**（旧 Opus 4.8） | `high` | ✅ |
| quality-reviewer | `opus` | **Opus 5**（旧 Opus 4.8） | `high` | ✅ |
| frontier-orchestrator | `fable` | Fable 5 | `high` | ✅ |
| frontier-reviewer | `fable` | Fable 5 | `high` | ✅ |
| frontier-solver | `fable` | Fable 5 | `high` | ✅ |

観察（**INFERRED**、設計判断の材料として）:

1. `deep-worker` / `quality-reviewer` は**ファイル無変更で Opus 5 に昇格済み**。Opus 5 は S3 いわく「delivers frontier intelligence at half the cost of Claude Fable 5」なので、**`fable` 3 エージェントとの能力差が縮まっている**。frontier-* 層の存在意義とルーティング閾値は再検討の余地がある。
2. `xhigh` が全 `model: opus` / `model: sonnet` / `model: fable` エージェントで利用可能になった（Sonnet 5 / Opus 5 / Fable 5 はいずれも 5 段階対応）。現状すべて `high` / `medium` 止まりで、**`xhigh` を一切使っていない**。S4（`claude-api` skill）は「`xhigh` は coding / agentic 用途のベスト設定で、Claude Code のデフォルト」と述べており、frontier-* / deep-worker の `xhigh` 化は検討に値する。
3. Opus 5 は「thinking on by default」「`thinking: disabled` は effort `high` 以下でのみ許可」（**CONFIRMED**、S3）。frontmatter に thinking 設定は無く、S1 いわく「subagents also inherit the main conversation's extended thinking configuration... **There is no per-subagent thinking setting**」（v2.1.198 以降）なので、リポジトリ側で対処すべきことは無い。
4. `fable` は ZDR 環境・組織アクセス次第で選択不能。フォールバック方針（`best` エイリアスの利用など）を決めておくと堅牢になる。

---

## CONFIRMED / INFERRED / UNKNOWN 一覧

| 項目 | 判定 |
|---|---|
| `model:` のエイリアスは `sonnet`/`opus`/`haiku`/`fable` の 4 つ | **CONFIRMED**（S1） |
| `model:` にフルモデル ID を書ける | **CONFIRMED**（S1） |
| `model:` に `inherit` を書ける／省略時デフォルトが `inherit` | **CONFIRMED**（S1） |
| `model:` に `best`/`opusplan`/`opus[1m]` 等のセッション用エイリアスが書けるか | **UNKNOWN**（S1 に記載なし） |
| Anthropic API で `opus` → Opus 5（v2.1.219 以降） | **CONFIRMED**（S2 + S5） |
| Microsoft Foundry では `opus` → Opus 4.6 のまま | **CONFIRMED**（S2） |
| `sonnet` → Sonnet 5（Anthropic API） | **CONFIRMED**（S2） |
| `fable` → Claude Fable 5、現存する | **CONFIRMED**（S2） |
| Fable 5 > Opus 5（能力・価格とも上位） | **CONFIRMED**（S2 `best` の定義 + S3 "half the cost of Claude Fable 5"） |
| `effort:` の値は `low`/`medium`/`high`/`xhigh`/`max` | **CONFIRMED**（S1） |
| frontmatter の `effort` はセッション effort を上書きする（環境変数には負ける） | **CONFIRMED**（S1 + S2） |
| Opus 5 / Sonnet 5 / Fable 5 は 5 段階全対応、Opus 4.6 / Sonnet 4.6 は `xhigh` 非対応、非掲載モデルは effort 非対応 | **CONFIRMED**（S2） |
| 未対応 effort はサイレントに直下のレベルへ丸められる | **CONFIRMED**（S2） |
| frontmatter に `ultracode` が書けるか | **UNKNOWN**（S1 の options に無いが明示的な否定も無い） |
| frontmatter の `effort: max` がセッション限定制約を受けるか | **UNKNOWN** |
| frontmatter の `effort` が API の `output_config.effort` にそのまま流れる | **INFERRED**（S1/S2 と S4 の値集合が一致することからの推論） |
| Opus 5 は 1M context がデフォルトかつ最大、小さい variant は無い | **CONFIRMED**（S3） |
| Anthropic API では `opus` エイリアス（Opus 5）で 1M が使える。別指定不要 | **CONFIRMED**（S2 + S3） |
| `opus[1m]` は Opus 5 に対して no-op か | **INFERRED**（S3 から論理的に導かれるが Claude Code 側の明言は未発見） |
| `[1m]` サフィックスを frontmatter `model:` に書けるか | **UNKNOWN**（用例が `/model` と環境変数のみ） |
| サブスク別 1M 課金表と Opus 5 の関係 | **UNKNOWN**（表が Opus 5 以前の記述に見える） |

## 未解決 / 追加調査したい点

- `opus[1m]` が Opus 5 でも意味を持つのか（Claude Code ドキュメントに Sonnet 5 相当の「Opus 5 context window」節が追加されるのを待つ）。
- サブエージェント frontmatter における `ultracode` / `[1m]` / セッション用エイリアスの可否。ドキュメント記載が無いため、実測（実際に定義を書いて起動し `modelUsage` を確認する）でしか埋まらない。
- frontmatter `effort` → API `output_config.effort` の対応を明示した一次情報。
