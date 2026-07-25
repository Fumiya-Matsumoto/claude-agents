# Codex を「系列外の独立レビュア」として起動する経路 — 一次情報 + 実機調査

- 調査日: 2026-07-25
- 対象 Issue: [#16](https://github.com/Fumiya-Matsumoto/claude-agents/issues/16)（親: #15）
- 実機: `codex-cli 0.145.0`（`codex --version` で確認）
- 既存設定: `~/.codex/config.toml` に `model = "gpt-5.6-sol"` / `model_reasoning_effort = "high"` / `approval_policy = "on-request"` / `sandbox_mode = "workspace-write"`
- 契約プラン: **ChatGPT Plus**（Pro / Business ではない）
- 本調査は**決定をしない**。選択肢とその要件・制約を並べるところまで。

## 凡例

| ラベル | 意味 |
|---|---|
| **CONFIRMED(docs)** | OpenAI 一次情報（公式ドキュメント）に明記 |
| **CONFIRMED(実機)** | ローカル 0.145.0 の `--help` 出力または実行結果で確認 |
| **INFERRED** | 一次情報から導出した推論。導出過程を併記し、反証可能にする |
| **UNKNOWN** | 一次情報が見つからなかった / 検証にクォータ消費が必要で未検証。推測で埋めていない |

## 情報源についての注意

- **公式ドキュメントの実体が移転している。** `https://developers.openai.com/codex/*` は 2026-07-25 時点で `https://learn.chatgpt.com/docs/*` へ **308 Permanent Redirect** する。本文では正規パスとして `developers.openai.com/codex/...` を記載するが、取得したのはリダイレクト先の内容。
- **実機がドキュメントより先行している箇所がある。** 後述の `codex exec review` は 0.145.0 に実在するが、公式 CLI リファレンス（`codex/cli/reference.md`）には掲載されていない。ドキュメントは `codex review` のみを記載する。**実機の `--help` を正とする。**
- 本調査では**プロンプトを実行していない**（クォータ消費を避けるため）。実行したのは `--help` と、API 到達前に落ちる preflight エラーの 2 件のみ。

---

## 1. 起動経路の一覧

| 経路 | 人間の手数 | 自動化の可否 | Plus で使えるか | repo から配布できるか |
|---|---|---|---|---|
| **A.** `codex exec "<prompt>"`（ローカル CLI 非対話） | 初回 `codex login` のみ。以後 0 | **可**（Claude Code の Bash からシェルアウト可） | **可**（Plus のローカルメッセージ枠を消費） | CLI 本体は各自インストール。レビュア定義は `.codex/agents/*.toml` で配布可 |
| **B.** `codex exec review --base <branch>`（差分レビュー専用・非対話） | 同上 0 | **可**（`--json` / `-o` あり） | **可** | 同上。レビュー観点は `AGENTS.md` の `## Code Review Rules` で配布可 |
| **C.** `codex review --base <branch>`（トップレベル版） | 同上 0 | **△**（`--json` / `-o` / `-s` / `-m` が**無い**。stdout をそのまま拾うのみ） | **可** | 同上 |
| **D.** `codex` TUI の `/review` スラッシュコマンド | 毎回、対話で数手 | **不可**（人間が張り付く） | **可** | レビュー観点は `AGENTS.md` で配布可 |
| **E.** GitHub PR に `@codex review` コメント | 初期設定（GitHub 連携 + リポジトリごとに Code review を ON）。以後 PR ごとにコメント 1 回 | **半自動** | **可**（Plus は Pricing の機能表に明記あり） | レビュールールは `AGENTS.md` を repo にコミットするだけで配布可 |
| **F.** GitHub「Automatic reviews」（PR オープンで自動発火） | 初期設定のみ。以後 0 | **全自動** | **可**（同上） | 同上 |
| **G.** GitHub Action `openai/codex-action@v1` | workflow 作成 + secret 登録 | **全自動** | **不可**（OpenAI **API キー**認証。ChatGPT サブスクでは動かない = 別課金） | workflow ごと repo にコミットして配布可 |
| **H.** Codex Cloud タスク（Web UI / `codex cloud exec --env <ID>`） | 環境作成が必要。以後はタスク投入 1 回 | **△**（CLI 投入は `[EXPERIMENTAL]`。`--env` 必須） | **可**（Plus は Cloud chats が機能表に明記あり） | 環境定義は Codex 設定側にあり、repo からは配布不可 |
| **I.** Slack / Linear 連携から起動 | 各連携の初期設定 + 都度メンション | **半自動** | **可**（Plus は機能表に明記あり） | 不可 |
| **J.** IDE 拡張 / デスクトップアプリの `/review` | 毎回、GUI 操作 | **不可** | **可** | レビュー観点は `AGENTS.md` で配布可 |
| **K.** Scheduled tasks（Automations） | デスクトップアプリで設定。以後 0 | **全自動**（ただしマシン起動 + アプリ常駐が条件） | **UNKNOWN**（プラン要件の明記なし） | 不可 |

> **Claude Code から自動で回すなら A / B、GitHub 側で回すなら E / F が現実解。** G は Plus 契約と無関係の API 課金になる点が最大の分岐点。

---

## 2. CLI の非対話実行（Issue 質問 1）

### 2-1. `codex exec` は存在する — **CONFIRMED(実機)**

`codex --help`（0.145.0）のサブコマンド一覧より:

```
exec            Run Codex non-interactively [aliases: e]
review          Run a code review non-interactively
```

`codex exec --help` の実機出力から確定した仕様:

| 項目 | 実機の仕様 |
|---|---|
| プロンプトの渡し方 | 引数 `[PROMPT]`。`-` を渡すか引数省略で **stdin から読む**。stdin がパイプされていてプロンプト引数もある場合、stdin は `<stdin>` ブロックとして**追記**される |
| 出力（既定） | 進捗は **stderr**、最終メッセージのみ **stdout**（`codex/non-interactive-mode.md`） |
| 出力（機械可読） | `--json` で **JSONL** をイベントストリームとして stdout に出力 |
| 出力（ファイル） | `-o, --output-last-message <FILE>` で最終メッセージをファイルに書き出し |
| 出力（構造化） | `--output-schema <FILE>` で JSON Schema を渡し、最終応答の形を固定できる |
| サンドボックス指定 | `-s, --sandbox <read-only\|workspace-write\|danger-full-access>` |
| 承認スキップ | **`codex exec` に `-a/--ask-for-approval` は無い**。`-c approval_policy=never` で指定する（`-a` はトップレベル `codex` 側のフラグ） |
| 危険フラグ | `--dangerously-bypass-approvals-and-sandbox`（承認もサンドボックスも無効化。レビュー用途では不要） |
| 設定の無視 | `--ignore-user-config`（`$CODEX_HOME/config.toml` を読まない。認証は `CODEX_HOME` から取る） |
| セッション非永続化 | `--ephemeral` |
| 作業ディレクトリ | `-C, --cd <DIR>` |
| プロファイル | `-p, --profile <NAME>` で `$CODEX_HOME/<name>.config.toml` を重ねる |

出典: 実機 `codex exec --help`（0.145.0）、および [Non-interactive mode](https://developers.openai.com/codex/non-interactive-mode.md)。

### 2-2. レビュー専用サブコマンドは 2 つある — **CONFIRMED(実機)**

**重要な差分。** `codex review` と `codex exec review` はフラグセットが違う。

| フラグ | `codex review` | `codex exec review` |
|---|:--:|:--:|
| `--uncommitted` / `--base <BRANCH>` / `--commit <SHA>` / `--title` | ✅ | ✅ |
| `[PROMPT]`（カスタムレビュー指示。`-` で stdin） | ✅ | ✅ |
| `--json`（JSONL 出力） | ❌ | ✅ |
| `-o, --output-last-message <FILE>` | ❌ | ✅ |
| `-m, --model` | ❌ | ✅ |
| `--output-schema <FILE>` | ❌ | ✅ |
| `--ephemeral` / `--ignore-user-config` / `--ignore-rules` / `--skip-git-repo-check` | ❌ | ✅ |
| `-s, --sandbox` | ❌ | ❌（どちらにも無い。`-c sandbox_mode=...` で指定する） |

**→ 自動化するなら `codex exec review` 一択。** `codex review` は出力を stdout から拾うしかなく、モデルもサンドボックスもフラグで切れない。

公式 CLI リファレンス（[Command line options](https://developers.openai.com/codex/cli/reference.md)）は `codex review` しか記載しておらず、`codex exec review` は**ドキュメント未記載**。実機 0.145.0 には存在する。

### 2-3. 終了コード — **一部 CONFIRMED(実機) / 一部 UNKNOWN**

公式リファレンスに終了コード表は**無い（UNKNOWN）**。実機で API 到達前に落ちる preflight エラー 2 件を検証した:

```
$ codex exec --output-schema /definitely/not/here.json "noop"
Failed to read output schema file /definitely/not/here.json: No such file or directory (os error 2)
EXIT=1

$ codex exec -s read-only "noop" < /dev/null     # git リポジトリ外
Not inside a trusted directory and --skip-git-repo-check was not specified.
EXIT=1
```

- **CONFIRMED(実機)**: 起動時エラーは **exit 1**、メッセージは stderr。
- **UNKNOWN**: 「レビューで指摘が出た場合に非ゼロを返すか」は未検証（検証にクォータを消費するため）。**CI のゲートに終了コードを使う設計は、この点を実測してから決めること。**
- **CONFIRMED(docs)**: `required = true` の MCP サーバが初期化に失敗すると「`codex exec` exits with an error instead of continuing without that server」（[Non-interactive mode](https://developers.openai.com/codex/non-interactive-mode.md)）。**`~/.codex/config.toml` には MCP サーバが 4 つ登録済み**なので、非対話実行では MCP 起動失敗が丸ごと失敗になりうる。`--ignore-user-config` で切り離す選択肢がある。

### 2-4. Claude Code の Bash からシェルアウトできるか — **可。ただし落とし穴が 2 つ**

**落とし穴 1: stdin。** 実機で確認したところ、stdin が TTY でない場合 `codex exec` は `Reading additional input from stdin...` と出して stdin を読みに行く。Claude Code の Bash ツールから呼ぶと stdin は TTY ではないため、**`< /dev/null` を必ず付ける**（付けない場合の挙動は環境依存で、意図しない入力が混ざるリスクがある）。

**落とし穴 2: 既定サンドボックス。** ドキュメントは `codex exec` の既定を read-only と述べるが、実機は `~/.codex/config.toml` の `sandbox_mode = "workspace-write"` を読み込む。**明示的に read-only を渡さないと書き込み可能で走る。**

実用形（未実行・レシピとしての提案）:

```bash
codex exec review --base main \
  --json -o /tmp/codex-review.md \
  -c sandbox_mode=read-only \
  -c approval_policy=never \
  --ephemeral \
  < /dev/null
```

- `-c` の値は TOML としてパースされ、失敗した場合は生文字列として扱われる（`codex --help` の `-c` 説明に明記）。したがって `-c sandbox_mode=read-only` はクォート無しで通る。
- **UNKNOWN**: `codex exec -s read-only review --base main` のように親の `-s` をサブコマンド前に置いて効かせられるかは未検証。`-c` 経由が確実。

---

## 3. カスタム定義の置き場所と repo からの配布（Issue 質問 2）

### 3-1. 手段は 4 つあり、repo 配布可否がはっきり分かれる

| 手段 | 置き場所 | repo から配布できるか | 出典 |
|---|---|:--:|---|
| **AGENTS.md** | `~/.codex/AGENTS.md`（グローバル）/ リポジトリルート / 任意のサブディレクトリ | ✅ **そのままコミットするだけ** | [Custom instructions with AGENTS.md](https://developers.openai.com/codex/agent-configuration/agents-md.md) |
| **サブエージェント定義** | `~/.codex/agents/*.toml`（個人）/ **`.codex/agents/*.toml`（プロジェクト）** | ✅ **プロジェクト側が個人側より優先** | [Subagents](https://developers.openai.com/codex/agent-configuration/subagents.md) |
| **プロジェクト設定** | **`.codex/config.toml`**（リポジトリ内） | ✅ ただし**プロジェクトを trust する必要あり** | [Advanced Configuration](https://developers.openai.com/codex/config-file/config-advanced.md) |
| **Skills** | `$CWD/.agents/skills` / `$REPO_ROOT/.agents/skills`（repo）/ `$HOME/.agents/skills`（個人）/ `/etc/codex/skills`（admin） | ✅ | [Build skills](https://developers.openai.com/codex/build-skills.md) |
| **Custom prompts** | `~/.codex/prompts/*.md` のみ | ❌ **repo 配布不可（公式に明言）**。かつ **skills に置き換えられ deprecated** | [Custom Prompts](https://developers.openai.com/codex/custom-prompts.md) |
| **Config profiles** | `$CODEX_HOME/<name>.config.toml`（= `~/.codex/` 直下） | ❌ ホーム限定 | [Advanced Configuration](https://developers.openai.com/codex/config-file/config-advanced.md) |

### 3-2. Custom prompts は使えない — **CONFIRMED(docs)**

> "live in your local Codex home directory (for example, `~/.codex`), so they're not shared through your repository."

さらに「Custom prompts are deprecated in favor of skills」。**claude-agents の symlink 配布方式を `~/.codex/prompts/` に適用するのは、公式が非推奨にした方向。**

なお実機の `~/.codex/prompts/` は**存在しない**（未使用）。

### 3-3. サブエージェント定義が本命 — **CONFIRMED(docs)**

`.codex/agents/reviewer.toml` を repo にコミットすれば、レビュア定義（モデル / effort / **サンドボックス** / 指示文）を丸ごと配布できる。公式ドキュメントの例がそのままレビュア用途:

```toml
name = "reviewer"
description = "PR reviewer focused on correctness, security, and missing tests."
model = "gpt-5.4"
model_reasoning_effort = "high"
sandbox_mode = "read-only"
developer_instructions = """
Review code like an owner.
Prioritize correctness, security, behavior regressions, and missing test coverage.
...
"""
```

- 必須フィールド: `name` / `description` / `developer_instructions`。
- 任意で `config.toml` の任意キーを載せられる（`model` / `model_reasoning_effort` / **`sandbox_mode`** / `mcp_servers` / `skills.config`）。
- **名前衝突時はプロジェクト側（`.codex/agents/`）が個人側（`~/.codex/agents/`）に勝つ。**
- 「Subagents inherit your current sandbox policy」だが、**エージェントファイル側で `sandbox_mode = "read-only"` を明示すれば上書きできる**。
- 実機の `codex features list` で **`multi_agent  stable  true`** を確認済み（**CONFIRMED(実機)**）。サブエージェント機能はローカルで有効。
- **起動方法は「チャットで依頼する」だけ**（"Ask Codex in an app chat to delegate…"）。**スラッシュコマンド / @メンション / CLI フラグでサブエージェントを直接指名する手段はドキュメントに記載が無い（UNKNOWN）。** → `codex exec` から特定のサブエージェントを名指しで起動できるかは未確定。プロンプト本文で名指しする運用になる可能性が高い（**INFERRED**）。

### 3-4. AGENTS.md の優先順位 — **CONFIRMED(docs)**

> "Codex concatenates files from the root down, joining them with blank lines. Files closer to your current directory override earlier guidance because they appear later in the combined prompt."

- グローバルは `~/.codex/AGENTS.md`（`AGENTS.override.md` があればそちらが優先）。
- 次にリポジトリルート、次にカレントディレクトリまでのサブディレクトリ。**深いほど後勝ち。**
- レビュー用途では `## Code Review Rules` セクションが専用に用意されている（GitHub の code review が読む。§4 参照）。
- 実機の `~/.codex/AGENTS.md` は**存在するが 0 バイト**（未使用）。

### 3-5. プロジェクト設定 `.codex/config.toml` — **CONFIRMED(docs)**

> "You can also add project-scoped overrides in `.codex/config.toml` files. Codex loads project-scoped config files only when you trust the project."

- カレントから上に向かって探索し、見つかったものを全て読む。同じキーは**作業ディレクトリに近い方が勝つ**。
- **trust が必須**: `projects.<path>.trust_level` が `"untrusted"` だと `.codex/` 層（config / hooks / rules）を丸ごと無視する。
- **プロジェクト設定で上書きできないキー**: `openai_base_url` / `chatgpt_base_url` / `apps_mcp_product_sku` / `model_provider` / `model_providers` / `notify` / `profile` / `profiles` / `experimental_realtime_ws_base_url` / `otel`。
- 実機バイナリの文字列にも一致する記述がある: `Project .codex/config.toml -> trusted-repo Codex settings such as sandbox, MCP, hooks, model, or reasoning defaults.`（**CONFIRMED(実機)**）
- **`sandbox_mode` は禁止リストに入っていない → プロジェクト側で read-only を固定できる（INFERRED、実測未了）。**

### 3-6. symlink 配布は使えるか — **INFERRED / 一部 UNKNOWN**

- **symlink の追従可否は公式ドキュメントに記載が無い（UNKNOWN）。**
- ただし実機の `~/.codex/skills/grill-me` が `../../.agents/skills/grill-me` への symlink として存在しており、実運用されている形跡がある（**CONFIRMED(実機) — 存在のみ。Codex が実際に解決しているかは未検証**）。
- **そもそも symlink を使う必要がない。** `.codex/agents/*.toml` / `AGENTS.md` / `.agents/skills/` は**対象リポジトリに直接コミットするだけで効く**。claude-agents が `~/.claude/agents/` へ symlink しているのは Claude Code 側にプロジェクトスコープの配布口が無いためで、Codex にはそれがある。**Codex 側は symlink 方式を踏襲しないほうが素直（INFERRED）。**

---

## 4. GitHub 上のレビュー自動化（Issue 質問 3）

### 4-1. 導入要件 — **CONFIRMED(docs)**

出典: [Codex code review in GitHub](https://developers.openai.com/codex/third-party/github.md)

前提条件:
1. **Codex cloud がそのリポジトリに対して設定済みであること**（"Codex cloud set up for the repository you want to review"）
2. Codex code review 設定へのアクセス
3. （任意）`AGENTS.md`

有効化: Codex 設定で **リポジトリごとに "Code review" を ON にする**。

Codex cloud 側のセットアップ（[Codex cloud](https://developers.openai.com/codex/cloud.md) / 検索結果より）: Codex にサインイン → **GitHub アカウントを接続し、Codex がアクセスできるリポジトリを選ぶ** → 環境設定でリポジトリ用の環境を作る。

- **UNKNOWN**: 「GitHub App のインストールが Codex cloud 設定とは別に必要か」は公式ドキュメントに明記が無い。ドキュメントは "Codex cloud set up" としか書かず、App インストールの独立ステップを示していない。

### 4-2. 発火条件 — **CONFIRMED(docs)**

| トリガー | 内容 |
|---|---|
| 明示トリガー | PR コメントに **`@codex review`**（この文字列そのまま） |
| 観点付き明示トリガー | `@codex review for security regressions` のように後ろに指示を足せる |
| 自動 | 設定で **"Automatic reviews"** を ON にすると「Codex will post a review whenever someone opens a new PR」= `@codex review` コメント不要 |

- 反応の目印: Codex が 👀 リアクションを付けてからレビューを投稿する。
- **GitHub 上では P0 / P1 の指摘のみに絞られる**（"Codex flags only P0 and P1 issues so review comments stay focused on high-priority risks"）。

### 4-3. レビュー観点の repo 配布 — **CONFIRMED(docs)**

`AGENTS.md` に `## Code Review Rules` セクションを置く。

> "Add a `## Code Review Rules` section to the file closest to the code the rules govern."

- リポジトリ全体のルールはルートの `AGENTS.md`、特定サービス向けは `services/example/AGENTS.md` のようにネストする。
- Codex は「変更された各ファイルをカバーするルート + より具体的なガイダンス」を適用する。
- 公式のルール記述ガイドライン: 「repository-specific behavior に絞る」「安全な経路や例外を明記する」「スコープを絞り長持ちするルールにする」「機械的チェックは CI に残す」。

### 4-4. **Plus で使えるか — 使える。CONFIRMED(docs)**

出典: [Pricing](https://developers.openai.com/codex/pricing.md) の機能表

- 「ChatGPT Work and Codex are included in your ChatGPT **Free, Go, Plus, Pro, Business, Edu, or Enterprise** plan.」
- 機能表上、**Code Review (GitHub) は Plus / Pro / Business / Enterprise / API Key で利用可。Free と Go は不可。**
- 「GitHub code review and automatic PR reviews」は **Plus / Pro / Business / Enterprise**。
- **Cloud chats も Plus / Pro / Business / Enterprise**（Free / Go / API Key は不可）。→ 前提条件の「Codex cloud」が Plus で満たせる。
- Slack / Linear の cloud integration も **Plus 以上**。
- 消費枠: 「Reviews run locally or outside of GitHub count toward your general usage limits.」→ **GitHub 上のレビューは一般利用枠の外側という読み方ができるが、明示的に「無料」とは書かれていない（INFERRED、要注意）。**
- Plus の枠は「local messages と cloud chats が **5 時間ウィンドウを共有**」。モデル別の目安として GPT-5.6 Sol が 15〜90 メッセージ / 5 時間、Terra 20〜110、Luna 50〜280。**現行の `~/.codex/config.toml` は `gpt-5.6-sol` = 最も枠の厳しい帯。**

### 4-5. GitHub Action は別物 — **CONFIRMED(docs)**

出典: [Codex GitHub Action](https://developers.openai.com/codex/github-action.md)

- アクション名: `openai/codex-action@v1`
- 認証: **OpenAI API キー**。「Store your OpenAI key as a GitHub secret (for example `OPENAI_API_KEY`) and reference it in the workflow.」
- **ChatGPT サブスクリプションでのログインは記載が無い → Plus 契約では動かない。API 従量課金になる（CONFIRMED(docs) + INFERRED）。**
- 入力として `prompt` / `prompt-file` / `model` / `effort` / `sandbox` / `safety-strategy` を取る。
- **→ 「Plus の枠内で完結させたい」なら G は選択肢から外れる。逆に「枠を食わずに回したい」なら唯一の道。**

---

## 5. その他の「Claude Code の外側」経路（Issue 質問 4）

| 経路 | 実体 | 人間の手数 | 備考 |
|---|---|---|---|
| **Codex Cloud（Web）** | chatgpt.com/codex | 環境作成（1 回）→ タスク投入 | Plus 可（Cloud chats） |
| **`codex cloud exec --env <ID> "<query>"`** | CLI から Cloud タスク投入 | `--env` の ID が必須 | `codex cloud --help` に **`[EXPERIMENTAL]`** と明記（**CONFIRMED(実機)**）。`--branch` / `--attempts`（best-of-N）あり |
| **`codex cloud list` / `status` / `diff` / `apply`** | Cloud タスクの一覧・差分取得・ローカル適用 | 都度 | 同上 EXPERIMENTAL |
| **IDE 拡張** | Codex IDE extension | GUI で毎回 | **UNKNOWN**（ドキュメントページが実質空で、対応 IDE / 認証 / プラン要件を確認できなかった） |
| **デスクトップアプリ / TUI の `/review`** | 対話レビューペイン | GUI で毎回 | 差分対象は uncommitted / base branch / commit / staged / last turn。既定は「現在のチャット内で実行」、設定で "Detached"（別チャット）に変更可 |
| **Scheduled tasks（Automations）** | 定期実行 | 設定 1 回 | **ローカル実行**。「Keep the computer on and the app running when a scheduled task needs local files」。Git リポジトリなら「dedicated background worktree」を選べる。サンドボックス（read-only / workspace-write / full access）も設定可。**プラン要件は UNKNOWN** |
| **Slack / Linear** | 連携先からメンションで起動 | 連携設定 + 都度 | Plus 以上（Pricing 機能表） |
| **`codex mcp-server`** | Codex を MCP サーバとして起動（stdio） | — | **Claude Code から MCP 経由で Codex を呼ぶ経路になりうる。** ただし本調査では未検証（**UNKNOWN**） |
| **`codex app-server` / `codex exec-server`** | いずれも `[experimental]` | — | 未調査 |

---

## 6. サンドボックスと権限（Issue 質問 5）

### 6-1. read-only に絞る手段

| 手段 | 書き方 | 適用範囲 |
|---|---|---|
| CLI フラグ | `codex exec -s read-only ...` / `codex -s read-only` | その実行のみ。**`codex review` / `codex exec review` には `-s` が無い** |
| `-c` 上書き | `-c sandbox_mode=read-only` | その実行のみ。**review サブコマンドでも使える** |
| ユーザ設定 | `~/.codex/config.toml` に `sandbox_mode = "read-only"` | 全体（現状は `workspace-write`） |
| プロジェクト設定 | repo の `.codex/config.toml` に `sandbox_mode = "read-only"` | その repo。**trust が前提**（INFERRED） |
| サブエージェント定義 | `.codex/agents/reviewer.toml` に `sandbox_mode = "read-only"` | そのエージェントのみ。**レビュア用途に最も筋が良い** |
| プロファイル | `~/.codex/reviewer.config.toml` + `-p reviewer` | ホーム限定・repo 配布不可 |

`--sandbox` の取りうる値は 3 つ（**CONFIRMED(実機)**）: `read-only` / `workspace-write` / `danger-full-access`。

各モードの定義（[Sandbox](https://developers.openai.com/codex/sandboxing.md)）:
- **read-only**: "The agent can inspect files, but it can't edit files or run commands without approval."
- **workspace-write**: "The agent can read files, edit within the workspace, and run routine local commands inside that boundary."（既定）
- **danger-full-access**: "The agent runs without sandbox restrictions. This removes the filesystem and network boundaries."

権限プロファイル側の記述（[Permissions](https://developers.openai.com/codex/permissions.md)）では read-only は「Allows commands to read files and list directories under the path」「Commands cannot create, modify, rename, or delete files there」。

> ⚠️ **read-only は「コマンドを一切実行しない」ではない。** ドキュメントの読み方が 2 か所で微妙に違う（sandboxing.md は「承認なしにコマンドを実行できない」、permissions.md は「読み取り系コマンドは許可」）。**非対話実行では承認できないため、`-c approval_policy=never` と組み合わせたときに read-only で何が通り何が失敗するかは実測が必要（UNKNOWN）。**

### 6-2. ネットワークの既定 — **CONFIRMED(docs)**

- 権限プロファイルの `permissions.<name>.network.enabled` の**既定値は `false`**（[Permissions](https://developers.openai.com/codex/permissions.md)）。**ネットワークは既定で遮断。**
- `workspace-write` サンドボックス内での外向き通信は `sandbox_workspace_write.network_access` で許可する（[Configuration Reference](https://developers.openai.com/codex/config-file/config-reference.md)）。**既定値はドキュメントに明記が無い（UNKNOWN）が、権限プロファイル側の既定 false と整合するなら無効（INFERRED）。**
- 実機バイナリの文字列に `sandbox_workspace_write` / `network_access` / `writable_roots` / `exclude_tmpdir_env_var` / `exclude_slash_tmp` の存在を確認（**CONFIRMED(実機)**）。
- `danger-full-access` は「removes the filesystem **and network** boundaries」。レビュー用途では使う理由が無い。
- なお `codex exec` には `--search`（web search 有効化）が**無い**（トップレベル `codex` のみ）。**非対話レビューは既定でネット無しで走る（INFERRED）。**

### 6-3. 承認ポリシー

`-a/--ask-for-approval` の取りうる値（**CONFIRMED(実機)**、トップレベル `codex` のヘルプより）:
- `untrusted`: 信頼済みコマンド（`ls`, `cat`, `sed` 等）のみ無承認で実行。それ以外は人間にエスカレーション
- `on-request`: モデルが承認を求めるタイミングを決める（**現行設定**）
- `never`: 承認を求めない。**実行失敗はそのままモデルに返る**

**`codex exec` / `codex exec review` に `-a` は無い。`-c approval_policy=never` を使う。**

---

## 7. 未確定事項（UNKNOWN）の棚卸し

決定の前に潰す必要があるもの:

1. **`codex exec review` の終了コード**（指摘があったときに非ゼロか）— CI ゲートに使うなら必須
2. **`codex exec` から特定のサブエージェント（`.codex/agents/reviewer.toml`）を名指し起動する手段**があるか
3. **read-only + `approval_policy=never` の組み合わせで、レビューに必要な `git diff` / `rg` 等が実行できるか**
4. **プロジェクト `.codex/config.toml` の trust をどう与えるか**（初回の対話が必要か、`projects.<path>.trust_level` を手で書けるか）
5. **GitHub code review が Plus の一般利用枠を消費するかしないか**（"Reviews run locally or outside of GitHub count toward your general usage limits" の裏返しが本当に「GitHub 上は消費しない」を意味するか）
6. **GitHub App のインストールが Codex cloud 設定と別途必要か**
7. **`~/.codex/agents/` や `.codex/agents/` で symlink が追従されるか**
8. **`codex mcp-server` 経由で Claude Code から Codex を MCP ツールとして呼べるか**（呼べるなら Bash シェルアウトより筋が良い可能性）
9. **IDE 拡張のプラン要件・対応 IDE**（ドキュメントページが取得できず）
10. **Scheduled tasks のプラン要件**

---

## 参照した一次情報

実機（すべて 0.145.0、プロンプト未実行）:
- `codex --version` / `codex --help` / `codex exec --help` / `codex review --help` / `codex exec review --help`
- `codex cloud --help` / `codex cloud exec --help` / `codex plugin --help` / `codex sandbox --help` / `codex features --help` / `codex features list`
- preflight エラーの終了コード実測 2 件
- 配布バイナリ内の文字列（`.volta/.../@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`）

公式ドキュメント（`developers.openai.com/codex/*` → `learn.chatgpt.com/docs/*` に 308 リダイレクト、2026-07-25 取得）:
- [Non-interactive mode](https://developers.openai.com/codex/non-interactive-mode.md)
- [Command line options](https://developers.openai.com/codex/cli/reference.md)
- [Codex code review in GitHub](https://developers.openai.com/codex/third-party/github.md)
- [Code review](https://developers.openai.com/codex/code-review.md)
- [Codex GitHub Action](https://developers.openai.com/codex/github-action.md)
- [Custom instructions with AGENTS.md](https://developers.openai.com/codex/agent-configuration/agents-md.md)
- [Subagents](https://developers.openai.com/codex/agent-configuration/subagents.md)
- [Custom Prompts](https://developers.openai.com/codex/custom-prompts.md)
- [Build skills](https://developers.openai.com/codex/build-skills.md)
- [Advanced Configuration](https://developers.openai.com/codex/config-file/config-advanced.md)
- [Configuration Reference](https://developers.openai.com/codex/config-file/config-reference.md)
- [Sandbox](https://developers.openai.com/codex/sandboxing.md)
- [Permissions](https://developers.openai.com/codex/permissions.md)
- [Pricing](https://developers.openai.com/codex/pricing.md)
- [Codex cloud](https://developers.openai.com/codex/cloud.md) / [Cloud environments](https://developers.openai.com/codex/environments/cloud-environment.md)
- [Scheduled tasks](https://developers.openai.com/codex/automations.md)
- [Documentation index (llms.txt)](https://developers.openai.com/codex/llms.txt)
