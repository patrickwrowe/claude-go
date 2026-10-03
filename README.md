# claude-go

Run **Claude Code on every OpenCode Go model**: MiniMax, Qwen, Kimi, GLM, DeepSeek,
MiMo, Grok and more, while plain `claude` keeps using your Anthropic subscription.

```
claude           ->  api.anthropic.com                          (your subscription, unchanged)
claude-go        ->  LiteLLM on 127.0.0.1:4141  ->  opencode.ai/zen/go
                        |- qwen*, minimax-*   : Anthropic Messages, forwarded as-is
                        |- glm, kimi, deepseek, mimo, longcat, hy : translated to Chat Completions
                        '- grok, gpt-5.6-luna : translated to the Responses API
```

Claude Code only speaks the Anthropic Messages API, and only the Qwen and MiniMax
models on Go do too. A local [LiteLLM](https://docs.litellm.ai/) proxy translates
for the rest, so one `claude-go` command reaches the whole catalog, including tool
calls. Everything is plain bash plus a pinned LiteLLM, installed per machine from this repo.

## Quick start

```bash
git clone <your-remote>/claude-go.git ~/src/claude-go
cd ~/src/claude-go
./install.sh                  # prompts for your OpenCode Go key (https://opencode.ai/auth)
claude-go-ctl test            # live check: one model per protocol, a few tokens
claude-go                     # Claude Code on Go (default model: minimax-m3)
```

Requirements: Linux or macOS (WSL on Windows), `bash`, `curl`, `git`, and Claude Code.
On Linux, also `bubblewrap` and `socat` for the Bash sandbox (see Guardrails).
The installer offers to install [uv](https://docs.astral.sh/uv/) if missing, then uses
it to install the pinned LiteLLM into an isolated tool environment.

## Daily use

```bash
claude-go                               # interactive, default model
claude-go --model kimi-k2.7-code        # any id from `claude-go-ctl models`
claude-go -p "summarize this repo"      # headless
claude-go --resume                      # resume an earlier claude-go session
claude-go --once -p "summarize this"    # stop the proxy afterwards (CI, one-shot runs)
```

The proxy stays running between calls so later `claude-go` runs start instantly. `--once`
(or `CLAUDE_GO_STOP_ON_EXIT=1`) stops it when `claude` exits, but only if that run started
it, so other sessions sharing the proxy are unaffected. `--once` must come before any
`claude` arguments.

Inside a session, `/model opus`, `/model sonnet` and `/model haiku` switch between the
three tier models, and `/model <id>` switches to any other catalog model.

| command | what it does |
|---|---|
| `claude-go-ctl models` | catalog, protocol per model, current tier mapping |
| `claude-go-ctl test [MODEL...]` | live round-trip through proxy to Go |
| `claude-go-ctl status` / `start` / `stop` / `restart` | proxy lifecycle (`claude-go` starts it on demand) |
| `claude-go-ctl logs [-f]` | proxy log (`~/.local/state/claude-go/proxy.log`) |
| `claude-go-ctl doctor` | dependencies, config, key, upstream, proxy |
| `claude-go-ctl sync-models` | diff the catalog against Go's live `/v1/models` |
| `claude-go-ctl regen` | rebuild `config/litellm.yaml` after editing the catalog |
| `claude-go-ctl update` | `git pull`, reinstall LiteLLM if the pin changed, regen, restart |
| `claude-go-ctl gastown` | print a Gas Town agent preset for claude-go |

## Configuration

Secrets and personal settings live **outside the repo** in `~/.config/claude-go/env`
(mode 600, created by `install.sh` from `config/env.example`):

| variable | default | meaning |
|---|---|---|
| `OPENCODE_GO_API_KEY` | (required) | your Go key |
| `LITELLM_MASTER_KEY` | generated | local key Claude Code uses to reach the proxy |
| `CLAUDE_GO_MODEL` | `minimax-m3` | model at startup |
| `CLAUDE_GO_OPUS_MODEL` | `kimi-k2.7-code` | `opus` alias, opus-tier subagents |
| `CLAUDE_GO_SONNET_MODEL` | `minimax-m3` | `sonnet` alias, sonnet-tier subagents |
| `CLAUDE_GO_HAIKU_MODEL` | `qwen3.8-flash` | background work (titles, summaries), Explore agent |
| `CLAUDE_GO_SUBAGENT_MODEL` | unset | force every subagent onto one model |
| `CLAUDE_GO_COMPACT_WINDOW` | unset | compact earlier for smaller-context models |
| `CLAUDE_GO_PORT` | `4141` | proxy port (127.0.0.1 only) |
| `OPENCODE_GO_BASE` | `https://opencode.ai/zen/go` | upstream |
| `CLAUDE_GO_CONFIG_DIR` | `~/.claude-go` | Claude Code state for claude-go sessions |
| `CLAUDE_GO_CUSTOM_HEADERS` | unset | extra request headers for Go, one `name: value` per line |

`claude-go` refuses to start when a tier names a model that isn't enabled in
`config/models.tsv`, such as a typo, a retired model or a disabled "contributor" model.
Otherwise the mistake would only surface when that tier is first used, and for the haiku
tier that happens quietly, in background work. `claude-go-ctl doctor` checks the tiers
too. The aliases `opus`, `sonnet` and `haiku` and a `[1m]` suffix are accepted.

Tier defaults favour models that are both capable and generous under Go's quotas.
Qwen3.8 Max, Qwen3.7 Max, Kimi K3, GLM-5.3 and Grok have small quotas (a few hundred
requests per 5 hours), so avoid them as the default or haiku tier.

**Why a separate Claude Code config dir?** Settings, session history and `/model`
choices live in Claude Code's config dir. Sharing `~/.claude` risks a Go model ID like
`kimi-k2.7-code` ending up in plain `claude` sessions, where it fails, and mixes the
two setups' session histories. The installer offers to symlink `CLAUDE.md`, `skills/`,
`agents/` and `commands/` from `~/.claude`, so your instructions and tooling carry over.
Anything you decline, or create in `~/.claude` later, is invisible to claude-go.
`~/.claude/settings.json` is never shared, so its permission rules, hooks and sandbox
settings don't apply either: copy the ones you rely on into `~/.claude-go/settings.json`.
`claude-go` prints a one-line note when part of `~/.claude` doesn't apply, and
`claude-go-ctl doctor` names each part. To silence the `CLAUDE.md` note without sharing,
create an empty `~/.claude-go/CLAUDE.md`.

The linked files are shared, so a claude-go session could otherwise change instructions and
skills that your subscription sessions trust. `config/claude-settings.json` denies the
model's file tools (Read, Edit, Write) access to the key file. It also denies writes to
`~/.claude`, to claude-go's Claude Code settings, `CLAUDE.md`, `skills/`, `agents/` and
`commands/`, and to this checkout's `bin/`, `lib/`, `config/` and `claude/`. Claude Code
itself only asks before some of these writes, so a person could still approve one. A
deny rule cannot be approved. To change these files, edit them outside claude-go.

## How it works

`bin/claude-go` loads your config, starts the proxy if needed, and `exec`s Claude Code with:

- `ANTHROPIC_BASE_URL` pointing at the proxy and `ANTHROPIC_AUTH_TOKEN` set to the local
  master key (Bearer auth, so there's no login prompt and your subscription login stays out of it).
  `OPENCODE_GO_API_KEY` is removed from Claude Code's environment, because only the proxy
  needs it and Claude Code passes its environment to every command the model runs;
- `ANTHROPIC_MODEL` and `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` mapped to Go models;
- `x-opencode-session: <uuid>` added via `ANTHROPIC_CUSTOM_HEADERS`. Go asks clients for a
  stable per-conversation session ID for routing and prompt caching. Your own
  `ANTHROPIC_CUSTOM_HEADERS` is **not** passed on. It is meant for Anthropic, often
  carries a gateway token, and the proxy forwards every `x-*` header to Go. Headers meant
  for Go go in `CLAUDE_GO_CUSTOM_HEADERS`;
- `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` and `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, so
  unknown betas don't cause errors and a per-request fingerprint doesn't defeat prefix caching.
- commit and PR attribution that names claude-go and the Go model the session started on
  (`Generated-by: claude-go … session started on minimax-m3, not a Claude model`). Claude
  Code's default, `Co-Authored-By: Claude Code <noreply@anthropic.com>`, would send anyone
  tracing a bad change to the wrong model.

`config/litellm.yaml` is **generated** from `config/models.tsv` by `scripts/gen-config.sh`:

| protocol in catalog | LiteLLM model | upstream endpoint |
|---|---|---|
| `messages` | `anthropic/<id>` | `/v1/messages` (native) |
| `chat` | `openai/<id>` | `/v1/chat/completions` |
| `responses` | `openai/responses/<id>` | `/v1/responses` |

Every deployment sends `User-Agent: claude-go/<version>`, because Go asks clients to
identify themselves rather than use a generic SDK name. The proxy forwards client `x-*`
headers upstream, which carries the session headers. Two proxy settings matter:
`drop_params: true` discards Anthropic-only parameters that translated backends
reject, and `use_chat_completions_url_for_anthropic_messages: true` stops LiteLLM
1.10x from sending Chat Completions models to the Responses API.

## Guardrails

Claude Code's defaults assume a Claude model is driving it, and some of them hand safety
decisions to that model. Under claude-go the model is a Go model, so
`config/claude-settings.json` overrides those defaults for every claude-go session.
`bin/claude-go` passes the file with `--settings`. Flag settings outrank
`~/.claude-go/settings.json` and a repository's `.claude/settings*.json`, so neither can
switch these back. To change one, edit the file in your clone.

- **Auto mode is off** (`permissions.disableAutoMode`). Auto mode lets a classifier approve
  tool calls in your place, and Claude Code runs that classifier on the sonnet-tier model,
  which is `CLAUDE_GO_SONNET_MODEL` here. With a fresh `~/.claude-go`, Claude Code 2.1.288
  started `-p` runs in auto mode. Sessions now start in the ask-before-acting mode, and
  `--permission-mode auto` is refused.
- **Bypass mode is off** (`permissions.disableBypassPermissionsMode`). Under bypass mode,
  a Go model runs every command without asking. Claude Code would only downgrade the
  request without saying so, so `claude-go` itself refuses `--dangerously-skip-permissions`,
  `--allow-dangerously-skip-permissions` and `--permission-mode bypassPermissions`. For
  unattended runs, use `--permission-mode dontAsk` and list what the session may do under
  `permissions.allow` in `~/.claude-go/settings.json`. Anything else is denied, and the
  session never waits on a prompt.
- **Hooks stay on** (`disableAllHooks: false`), so a cloned repository's settings cannot
  switch off your hooks.
- **Bash runs in Claude Code's sandbox** (`sandbox`). It contains commands you approve,
  including scripts whose contents Claude Code cannot inspect, such as `npm test`. Such
  commands can write inside the working directory but not elsewhere in your home
  directory, `~/.claude`, claude-go's settings or this checkout's `bin`, `lib`, `config`
  and `claude`. They cannot read the key file, and they do not see `OPENCODE_GO_API_KEY`
  or the proxy key. Network access needs approval per host. Allow hosts with
  `sandbox.network.allowedDomains` in `~/.claude-go/settings.json`. Each sandboxed
  command still asks for permission (`autoAllowBashIfSandboxed: false`), because
  Claude Code's default auto-allows them. The model cannot opt a command out of the
  sandbox (`allowUnsandboxedCommands: false`). Under Claude Code's default, it could do
  that and run an allowed command unsandboxed without a prompt. List commands that
  cannot work sandboxed, such as `docker`, under `sandbox.excludedCommands` in
  `~/.claude-go/settings.json`. They still ask for permission. On Linux the sandbox needs `bubblewrap` and
  `socat`. Without them Claude Code warns and runs Bash unsandboxed, and
  `claude-go-ctl doctor` flags it.

**The claude-go skill is mandatory.** `claude/plugins/claude-go` is loaded into every
session with `--plugin-dir`. Normally the model decides whether to load a skill, and a
model that is drifting from its instructions is the one least likely to. So the plugin's
SessionStart hook puts the full text of `skills/claude-go/SKILL.md` in front of the model
at startup and again after compaction. Resumed sessions keep it in their history. The
rules cover following CLAUDE.md, treating permission denials as final, stopping before
destructive or outward-facing actions, keeping secrets, and checking and honestly
reporting its own work. Edit SKILL.md to change them. `claude-go` refuses `--bare` and
`--safe-mode`, and `CLAUDE_CODE_SIMPLE` / `CLAUDE_CODE_SAFE_MODE` in the environment,
because each switches off hooks, plugins and CLAUDE.md.

`claude-go` refuses a `--settings` argument, because Claude Code keeps only the last one
and would drop these. Put personal settings in `~/.claude-go/settings.json`.

**Destructive commands need a person.** `claude/plugins/claude-go-guard` adds a PreToolUse
hook (`hooks/guard.py`). It answers "ask" for Bash commands that destroy work or rewrite
shared history, so a person must approve them even where an allow rule, `acceptEdits` or
`dontAsk` would let them run. Headless runs refuse them and tell the model why. Claude
Code already asks before `rm -rf` outside the repo. It does not ask for git: with an
allow rule such as `Bash(git:*)`, it runs `git reset --hard`, `git checkout -- .`,
`git clean -fdx` and `git push --force` unasked. The guard covers those, plus `rm -r` of
the whole repo or anything outside it, `find -delete` outside it, recursive
`chmod`/`chown` of the home directory, `curl | sh`, `dd` onto devices and `mkfs`. It
catches mistakes. It is not a security boundary, because an obfuscated command can get
past any parser. Commands it cannot parse go to a person.

## Maintenance

**New or retired Go models.** Run `claude-go-ctl sync-models`. For each new ID, look up
its endpoint in the Endpoints table at https://opencode.ai/docs/go/, add a line to
`config/models.tsv`, run `claude-go-ctl regen`, and commit.

**LiteLLM upgrades.** The version is pinned in `config/LITELLM_VERSION`. LiteLLM
1.82.7 and 1.82.8 on PyPI were compromised with a credential stealer in March 2026;
the installer and doctor refuse them. To upgrade, bump the pin, run
`test/offline.sh`, then commit. Other machines pick it up with `claude-go-ctl update`.

**New machine.** Clone, `./install.sh`, done. Only the key needs to be entered per machine.

## Testing

`test/offline.sh` needs no key and no network access to Go. It starts `test/mock_go.py`
(a fake Go API speaking all three protocols) and a real LiteLLM proxy with the generated
config, then asserts, per protocol and for streaming and non-streaming requests:

- the upstream path;
- the auth header;
- the `claude-go/*` User-Agent;
- the session headers;
- that the proxy key never leaks upstream.

If `claude` is installed, it also runs real headless Claude Code turns, including a
**tool call round-trip**. The mock requests `Bash`, Claude Code runs it, and the
result must make it back through the translation.

Run it after any change to the catalog, generator, or LiteLLM pin.

`test/instructions.sh` answers "does claude-go read my instructions?" It runs the real
Claude Code through `bin/claude-go` in fresh repositories, with `test/fake_proxy.py`
logging every request. It checks that `CLAUDE.md`, its `@imports`, `.claude/CLAUDE.md`,
`CLAUDE.local.md`, `AGENTS.md` (when there is no `CLAUDE.md`), a nested `CLAUDE.md` once
the model works in that directory, and `~/.claude-go/CLAUDE.md` all reach the model. It
also pins that plain claude's `~/.claude/CLAUDE.md` does **not**, unless it is linked.
`test/offline.sh` checks that `CLAUDE.md` survives LiteLLM's translation for every
protocol.
`test/catalog.sh` checks that the committed `config/litellm.yaml` matches
`config/models.tsv`. It also checks that malformed rows stop generation: spaces instead of
tabs, an `enabled` value other than `yes`/`no`, duplicate ids (LiteLLM would load-balance
between them), unknown protocols, and ids that would break the YAML.

`test/lifecycle.sh` needs nothing installed besides `bash`, `curl` and `python3`. A fake
`litellm` and a fake `claude` exercise `bin/claude-go` and the proxy lifecycle: start on
demand and reuse, argument pass-through, `--once` teardown (including on Ctrl-C), the proxy
surviving a Ctrl-C to its terminal, PID-file checks, and the macOS path without `setsid`.
Run it after any change to `bin/claude-go` or `lib/common.sh`.

`test/settings.sh` checks the guardrails against the installed Claude Code, which also
catches a Claude Code upgrade that renames a setting. `test/fake_proxy.py` stands in for
the proxy and logs every request in full. The test needs `claude` and `python3`, but no
LiteLLM, key or network. Run it after any change to `config/claude-settings.json` and after
upgrading Claude Code. `test/bypass.sh` does the same for bypass mode and the `dontAsk`
mode that the Gas Town preset uses.
`test/uninstall.sh` runs `install.sh` and `uninstall.sh` in a throwaway HOME with a fake
`uv`. It checks that `--purge` never deletes a home directory or `~/.claude`, and that
neither script removes or replaces a LiteLLM that claude-go didn't install.
`test/secrets.sh` samples `ps` while `claude-go-ctl status`, `sync-models` and `test`
talk to deliberately slow fake endpoints. Neither key may appear in any process's
arguments. It also round-trips a key containing `' & | \ $ ;` and spaces through
`install.sh`.

## Rollout plan

1. **One machine, offline.** Clone, `./install.sh`, then `test/offline.sh` (confirms LiteLLM
   and Claude Code versions translate correctly on this machine).
2. **Live.** `claude-go-ctl doctor`, then `claude-go-ctl test` and
   `claude-go-ctl test qwen3.8-flash glm-5.2 deepseek-v4-flash` to sample each model family.
3. **Shadow use for a week.** Use `claude-go` for low-stakes work (docstrings, test
   scaffolding, log triage). Note which models handle Claude Code's tool use well, and
   adjust tiers in `~/.config/claude-go/env`. Watch usage at https://opencode.ai/auth.
4. **Commit the tuning.** Put good defaults in `config/env.example` or the catalog notes,
   push, and install on your other machines.
5. **Orchestration (optional).** `claude-go-ctl gastown` prints an agent preset. It uses
   `--permission-mode dontAsk` rather than the built-in Claude preset's
   `--dangerously-skip-permissions`, so first allow what polecats need in
   `~/.claude-go/settings.json`. Route
   polecats and witnesses to `claude-go` and keep the Mayor on your subscription. For
   Claude Code agent teams, note that teammates share one session's backend, so a team
   runs entirely on claude-go or entirely on your subscription.

## Limitations

- **Server-side Anthropic tools** such as Claude Code's web search run on Anthropic's API and
  are not available through Go models. Local tools (Bash, Read, Edit, Grep, WebFetch...) work.
- **Translation is not lossless.** Extended-thinking blocks, images for non-vision models,
  and some Anthropic-specific request fields are dropped for Chat Completions and Responses
  models. The Qwen and MiniMax models avoid translation entirely, so start there if
  a translated model misbehaves.
- **Context windows.** Claude Code applies its own default window to model names it
  doesn't recognize. If a model errors on long sessions, set `CLAUDE_GO_COMPACT_WINDOW`.
- In `-p` mode Claude Code prints `[claude-code:unrecognized_model]` for non-Anthropic
  model IDs. This is informational only.
- **Privacy differs by model.** The Muse Spark "Contributor" models train on your prompts
  and are disabled in the catalog. Grok and GPT 5.6 Luna have 30-day retention; most others
  are zero-retention. Check the Privacy table on the Go docs page before sending
  proprietary code.

## Troubleshooting

| symptom | fix |
|---|---|
| `proxy exited during startup` | `claude-go-ctl logs`; usually a YAML typo after editing the catalog: `claude-go-ctl regen` |
| `port 4141 is in use` | set `CLAUDE_GO_PORT` in `~/.config/claude-go/env` |
| 401 from upstream | wrong Go key: edit `~/.config/claude-go/env`, `claude-go-ctl restart` |
| `the running proxy still uses the env from before your last change` | the proxy reads keys and config only at start: `claude-go-ctl restart` (this ends in-flight requests of other claude-go sessions) |
| 429 / usage limit | Go quota for that model is exhausted; switch model or wait for the 5-hour window |
| one translated model fails, others work | `claude-go-ctl test <model>` for the raw error; try the same task on a `messages` model |

## Repository layout

```
bin/claude-go          launcher (execs claude with proxy env)
bin/claude-go-ctl      management CLI
lib/common.sh          shared shell helpers (config, proxy lifecycle)
config/models.tsv      model catalog: the one file to edit when Go changes
config/litellm.yaml    generated proxy config (committed so installs need no generation step)
config/env.example     template for ~/.config/claude-go/env
config/LITELLM_VERSION pinned LiteLLM release
config/claude-settings.json  guardrails passed to every session with --settings
claude/plugins/        plugins loaded into every session (claude-go: the mandatory skill;
                       claude-go-guard: destructive commands)
scripts/gen-config.sh  catalog -> litellm.yaml
test/offline.sh        offline end-to-end test (mock Go + real LiteLLM + real Claude Code)
test/mock_go.py        fake Go API (Messages, Chat Completions, Responses, tool calls)
test/instructions.sh   which instruction files reach the model (fake proxy + real Claude Code)
test/lifecycle.sh      proxy lifecycle test (fake LiteLLM + fake Claude Code)
test/settings.sh       guardrail test (fake proxy + real Claude Code)
test/bypass.sh         bypass mode stays off; dontAsk preset (real Claude Code)
test/skill.sh          the mandatory claude-go skill reaches the model (real Claude Code)
test/guard.sh          destructive-command guard: decision table + real Claude Code
test/sandbox.sh        the Bash sandbox contains an allowed script (real Claude Code)
test/deny.sh           file tools cannot touch the key file or guardrails (real Claude Code)
test/attribution.sh    commit/PR attribution names claude-go and the model (real Claude Code)
test/fake_proxy.py     fake proxy that logs every request Claude Code sends
test/claude_harness.sh shared harness for the real-Claude-Code tests
install.sh / uninstall.sh
install.sh / uninstall.sh   (uninstall.sh --purge also deletes keys, state and sessions)
```
