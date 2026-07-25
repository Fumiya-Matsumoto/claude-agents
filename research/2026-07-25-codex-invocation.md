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

---

# 追記（2026-07-26）— #22 の実機検証: 非対話レビューは成立するか

**このセクションは [#22](https://github.com/Fumiya-Matsumoto/claude-agents/issues/22) の結果。** 本体（2026-07-25）が「クォータ消費なしでは確かめられない」として UNKNOWN で残した 3 件を実機で潰した。

## 0. 測定条件

- Codex CLI **0.145.0**、`model = "gpt-5.6-sol"` / `model_reasoning_effort = "high"`（`~/.codex/config.toml` の既定をそのまま使用）。
- **消費実測**: `codex app-server` の `account/rateLimits/read` を実行前後で読む（消費ゼロ）。週次枠 `usedPercent` は **実行前 4% → 実行後 6%**。
- **成功した review 実行は 4 回**（下記 run1〜run4c）。**≒ 0.5% / 回**。ほかに引数エラーで API 到達前に落ちた実行が 3 回（**消費ゼロ**）。
- `~/.codex/config.toml` は**書き換えていない**。trust は `-c` でその実行限りに付与した。`.codex/agents/reviewer.toml` は作業ツリーに置いただけで**コミットせず、検証後に削除**した。

| run | 対象 | 差分規模 | 終了コード | 所要 | 指摘 |
|---|---|---|---|---|---|
| run1 | `claude-agents` `--commit f6abd97` | 約 290 行 / 11 ファイル | **0** | 178s | P2 × 1 |
| run2 | scratch `--commit 1c67380`（バグ仕込み） | 12 行 | **0** | 112s | P2 × 2 |
| run3 | scratch `--commit e1e9373`（docstring のみ） | 4 行 | **0** | 28s | **0 件** |
| run4c | scratch PROMPT のみ（サブエージェント名指し） | 12 行 | **0** | 182s | P1 × 1 + P2 × 1 |

---

## A. read-only + `approval_policy=never` は通る — **CONFIRMED(実機)**

**本体 §6 が「実測が必要」とした最重要項目。結論: 通る。自動起動経路 (b) は死んでいない。**

run1 で Codex が実行したシェルコマンドは **7 本すべて `exit=0` / `status=completed`**。承認要求は 1 度も発生せず、サンドボックス由来の失敗もゼロ。通ったもの:

```
git show / git log / git rev-parse / git remote / git status
grep / find / sed / nl / cat / printf
```

→ ドキュメントの食い違い（`sandboxing.md`「承認なしにコマンド実行不可」vs `permissions.md`「読み取り系は許可」）は **`permissions.md` が正しい**。`sandboxing.md` の記述は非対話実行の実態と一致しない。

**#18 への含意: 選択肢 (b) は消えない。** ただし下の B と C の条件が付く。

## B. ネットワークはシェルでは遮断されるが、**MCP プラグインは素通りする** — **CONFIRMED(実機)**

run1 で 2 つが同時に観測された:

- Codex が実行した `gh issue view` は **`error connecting to api.github.com`** で失敗（`sandbox_workspace_write.network_access = false` と整合）。
- **にもかかわらず、`codex_apps` MCP サーバの `github.fetch_issue` / `github.fetch_issue_comments` は成功し**、Issue **#3 / #6 / #7 / #8 / #9 / #10 / #11 / #12 / #13 の本文と全コメントを取得した**（`github@openai-curated` プラグインが有効なため）。

**サンドボックスはモデルのシェルにしか掛かっていない。MCP ツールは別経路で、read-only でも外部通信する。** 「read-only にしたから外に出ない」は**誤り**。

**#20 への含意（大きい）**: コンテキスト境界は `-c sandbox_mode=read-only` では引けない。Codex は指示していないのに**前マップ #3 の決定履歴を丸ごと読み込んだ**。渡す範囲を絞りたいなら、プラグインを切る（`-c plugins."github@openai-curated".enabled=false`）ほうを設計に入れる必要がある。

## C. read-only は「リポジトリ内読み取り」ではなく **ディスク全体の読み取り** — **CONFIRMED(実機)**

run1 で Codex はリポジトリ外を読んだ:

- `/Users/fumiya/.codex/memories/MEMORY.md`（個人メモリ）
- `/Users/fumiya/.agents/skills/code-review/SKILL.md`
- `find` が親ディレクトリを走査し、**別プロジェクトのファイル名が出力に載った**（`../ui/CONTRIBUTING.md` / `../drgym/CLAUDE.md` / `../runup/AGENTS.md` / `../posuraku/CLAUDE.md` / `../tenakan/AGENTS.md`）。

**マップの Notes は「Issue 本文にプロジェクト固有情報を書かない」を掲げているが、Codex 側はレビュー中に隣接リポジトリを覗ける。** 公開リポジトリのレビューに使う際の前提として記録しておく。`-C/--cd` や `--add-dir` は**書き込み側の制御**であって読み取りを閉じないことに注意。

## D. 終了コードは「指摘の有無」を伝えない — **CONFIRMED(実機)。設計を 1 つ潰した。**

本体 §2-3 が UNKNOWN とした核心。**答え: 区別できない。**

| 状況 | 終了コード | 根拠 |
|---|:--:|---|
| レビュー実行成功・**指摘あり**（P1/P2 が出た） | **0** | run1 / run2 / run4c |
| レビュー実行成功・**指摘なし** | **0** | run3（「no actionable defects」と明言して 0） |
| preflight 失敗（git repo 外 等） | **1** | 本体 §2-3（既測） |
| **CLI 引数エラー** | **2** | 本項で新規発見（下記 G） |

→ **`codex exec review` の終了コードを CI ゲートに使うことはできない。** 「指摘が出たら落とす」は終了コードでは実装できず、**`-o` の出力本文をパースするしかない**。

**#17 が導いた設計要件「非対話実行の終了コードとエラー文言を握りつぶさない」は、半分しか満たせない**: 「失敗した／起動できなかった」は終了コードで捕まえられるが、「指摘が出た」は捕まえられない。**#18 / #21 はこの前提で組む必要がある。**

## E. 枠切れ時の終了コードは**実測していない** — **UNKNOWN（意図的に残す）**

#17 の追記は「指摘あり / 実行失敗 / 枠切れ の 3 つを終了コードで区別できるか」まで見ることを求めていたが、**枠切れの実測は週次枠を 96% 燃やすことを意味する**ため実行しなかった。費用が発見の価値を大きく超える。

ただし **D で既に判定に足りる**: 「指摘あり」と「指摘なし」が同じ 0 である以上、枠切れが 1 だろうが別値だろうが**ゲート設計は成立しない**。#17 が枠切れの重要度を上げた理由（サイレントフォールバックの排除）は本体 §2-3 とバイナリ解析で既に CONFIRMED であり、**新たに消費して確かめる必要はない**。

## F. `--json` は消費量を返さない — **CONFIRMED(実機)**

`turn.completed` イベントの `usage` は **全フィールド 0**:

```json
{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,
 "cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}
```

→ **`codex exec review --json` からコストを読むことはできない。** #17 の「`exec --json` に rate-limit 出力は無い」を、review サブコマンドでも確認。**消費を測る手段は `codex app-server` の `account/rateLimits/read` 一本**（#17 §6）で変わらない。運用で消費を監視するなら、実行を挟んで前後 2 回読む形になる。

## G. `[PROMPT]` は 3 つの対象指定フラグと**排他** — **CONFIRMED(実機)。新規発見。**

```
error: the argument '--commit <SHA>' cannot be used with '[PROMPT]'
error: the argument '--base <BRANCH>'  cannot be used with '[PROMPT]'
error: the argument '--uncommitted'    cannot be used with '[PROMPT]'
```

`codex exec review` は排他的な **4 モード**:

1. `--commit <SHA>` 2. `--base <BRANCH>` 3. `--uncommitted` 4. `[PROMPT]`（散文で対象を説明する）

→ **明示的な差分対象を指定しながら、レビュー観点を引数で渡すことはできない。** レビューの内容を形作る経路は以下に限られる:

- `AGENTS.md` の **`## Code Review Rules`** 節（リポジトリにコミットして配布可）
- `-c` による config 上書き
- PROMPT モードに切り替える（ただし対象指定は散文になり、再現性が落ちる）

**#20「レビュー用プロンプトの固定」への含意**: 対象を機械的に固定したいなら観点は `AGENTS.md` に置くしかない。両方を引数で渡す設計は取れない。

なお引数エラーは **API 到達前に落ちるため消費ゼロ**。フラグの組み合わせ検証は無料で回せる。

## H. サブエージェント（`.codex/agents/*.toml`）は `codex exec review` から起動できない — **CONFIRMED(実機)。本体 §3-3 の結論を否定する。**

本体は `.codex/agents/reviewer.toml` を「**本命**」としたが、**この経路では効かない。**

**静的証拠（消費ゼロ）:**
- `codex` / `codex exec` / `codex exec review` の `--help` に **`--agent` / `--subagent` 相当のフラグは無い**。`codex agent` サブコマンドも無い。
- `-p/--profile` は存在するが **`codex exec` にのみ**あり、**`codex exec review` には無い**。しかも参照先は `$CODEX_HOME/<name>.config.toml` で**ホーム限定**、リポジトリから配布できない。
- バイナリ文字列上、サブエージェントは `<subagents>` として `collaboration_mode` 内のプロンプトに列挙される形。すなわち**委譲はプロンプト経由**の想定。

**実機証拠（run4c）:** プロジェクトを `-c projects."...".trust_level="trusted"` で信頼させ、`.codex/agents/reviewer.toml` を置き、PROMPT で明示的に「`reviewer` サブエージェントに委譲し、その `developer_instructions` に厳密に従え」と指示した。結果:

- `reviewer.toml` の `developer_instructions` に埋めた検証マーカー **`WF22-SUBAGENT-REVIEWER-RAN` は出力に 1 度も現れなかった**。
- JSONL のイベント型は **`command_execution` と `agent_message` のみ**。委譲を示すイベントは**存在しない**。
- Codex は `.codex/agents/reviewer.toml` を **`cat` で平文として読んだだけ**で、エージェント定義としては解釈も遵守もしなかった。

→ **レビュアの model / effort / sandbox をサブエージェント定義で固定する設計は、`codex exec review` では成立しない。** 固定手段は **`-c` フラグの列挙**（`-m` / `-c model_reasoning_effort=...` / `-c sandbox_mode=...`）と **`AGENTS.md`** に限られる。**本体 §3-3 の「本命」判定は、`codex exec review` 経路に関しては誤り**として訂正する。

（対話 TUI やデスクトップアプリでの委譲は本項の検証範囲外。否定しているのは **`codex exec review` からの名指し起動**のみ。）

## I. 副次観測: レビュー品質と再現性

- scratch に仕込んだ **`percentile(values, p=1)` の `IndexError`（`idx == len(s)`）を 2 回とも検出**した。指摘は具体的で、行番号も正確。
- ただし**同一差分・同一設定でも優先度がぶれた**（run2 は P2、run4c は同じ欠陥を P1）。**優先度を閾値にした自動ゲートは不安定**になる。
- run3（docstring 追加のみ）では**指摘を捏造せず 0 件で返した**。偽陽性を撒く挙動は観測されなかった。
- run1 が claude-agents の実差分に付けた指摘は「README:78 の Sonnet 専用枠という前提が誤り」。**これは実際に正しい指摘**だが、`6bf453a` で既に修正済みの内容だった（Codex は `f6abd97..HEAD` を読んだうえでこう述べている）。

---

## この検証が #22 の受け入れ基準に対して返した答え

| 受け入れ基準 | 結果 |
|---|---|
| 3 件が UNKNOWN でなくなっている | **達成**（1→A、2→D、3→H）。枠切れ終了コードのみ意図的に UNKNOWN（E に理由） |
| 叩いたコマンドと生出力（終了コード込み）が記録されている | **達成**（§0 の表と各項） |
| 1 件目が「通らない」だった場合に #18 の選択肢 (b) が消えることを明記 | **該当せず** — A で「**通った**」ため **(b) は消えない**。ただし B / C / D / G / H が (b) に条件を付ける |
| 消費したクォータの実測値 | **達成** — 4 回で週次枠 **2%**（4%→6%）、**≒0.5% / 回** |
| 記録は `research/codex-invocation` ブランチに追記 | **達成**（本追記） |

## 消費の見立ての更新（#17 の数字を実測で締める）

- #17 の推定「レビュー 1 回 ≒ 枠の 0.5〜1.5%」に対し、**実測は下限側の ≒0.5%**。
- 内訳の傾向も #17 と整合: **大きい差分 + MCP による Issue 取得を伴う run1 が単独で ≒1%**、小さい scratch の 3 回で合計 ≒1%。**支配するのは投入コンテキスト量**であり、B の MCP 素通りが**そのまま消費増**に効いている。
- 単純外挿で **週あたり 200 回前後**。#17 が置いた「1 日 5〜10 回」という保守的な線より**かなり余裕がある**。ただし週次枠は ChatGPT の Work / Excel とも共有される 1 本なので、対話利用と食い合う前提は変わらない。
