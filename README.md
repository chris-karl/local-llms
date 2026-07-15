# local_LLMs

Local Qwen models on a 16 GB M1 Pro, for two jobs:

- **CLI chat, no server** — `./chat.sh qwen-9b`
- **A local backend for Claude Code** — `./serve.sh`, then `./claude-local/claude-local.sh`

`models.ini` is the single source of truth for both. Add a model once there and
it shows up in `./chat.sh` and in Claude Code's `/model` picker.

## Files

| File            | What it does                                                                            |
|-----------------|-----------------------------------------------------------------------------------------|
| `models.ini`    | Every model + its tuned flags. Edit this, not the scripts.                              |
| `chat.sh`       | Interactive `llama-cli` chat, with a model picker. No server, no port.                  |
| `serve.sh`      | `llama-server` in router mode, for Claude Code.                                         |
| `claude-local/` | Runs Claude Code against the router, plus install/uninstall.                            |
| `templates/`    | Each model's chat template, patched. Claude Code doesn't work without this — see below. |

## CLI chat

Run it bare and pick from a menu:

```
$ ./chat.sh
Available models:

  1) qwen-9b          Q8_0     64K ctx   images
  2) qwen-27b         IQ3_XS   8K ctx    text
  3) qwen-27b-images  IQ3_XS   8K ctx    images

Choose [1-3, q to quit]:
```

Or skip the menu:

```sh
./chat.sh qwen-9b
./chat.sh qwen-9b --ctx-size 4096   # extra args pass through and win
```

This is `llama-cli` — nothing listens on a port.

It's also the path that *downloads* a model, via `llama-cli --hf-repo`. So a
new model is: add a preset, run `./chat.sh <name>` once to pull it, and
`serve.sh` can use it too.

**Switching models means restarting.** `llama-cli` binds one model at startup
and has no in-session `/model`; only the router (`serve.sh`) can swap. A swap
costs a full unload+reload anyway, so `q` and re-pick is no slower — you just
lose the conversation.

## Claude Code against a local model

```sh
./serve.sh                        # terminal 1: router on 127.0.0.1:8080
./claude-local/claude-local.sh    # terminal 2: Claude Code, wired to it
```

Inside, `/model` lists every model from `models.ini` — as `claude-qwen-9b`,
`claude-qwen-27b`, … — and switches between them live, unloading the old model
before loading the new one. The prefix is not cosmetic; see the notes.

`claude-local.sh` only sets env vars for its own process, so a plain `claude`
in any other terminal still uses the real Anthropic API.

### Using it from anywhere

`claude-local.sh` reaches the router over HTTP and doesn't care where it's run
from, so it works in any project once it's on your PATH:

```sh
./claude-local/install.sh      # symlink -> ~/.local/bin/claude-local
cd ~/some/other/project
claude-local                   # needs ./serve.sh running, as always
```

`install.sh` symlinks rather than copies, so edits here take effect at once —
but moving this repo breaks the link, and re-running it fixes it. If the target
dir isn't on your PATH, it appends a guarded block to the rc file of your login
shell, auto-detected (zsh, bash, fish, ksh, else `~/.profile`); then `. ~/.zshrc`,
or open a new terminal. Install elsewhere with
`BIN_DIR=/usr/local/bin sudo ./claude-local/install.sh`, or pass `--no-rc` to
link only and leave your shell config untouched.

`./claude-local/uninstall.sh` is the exact inverse: it drops the symlink, the
PATH block, and the bin dir, leaving no trace. Each step is scoped to what
`install.sh` made — only a link pointing back here, only the marker-delimited
block (a PATH line you wrote yourself isn't matched), and only an empty dir.

### Why there's no proxy here

The usual advice is that Claude Code needs an Anthropic→OpenAI translation
proxy (LiteLLM, claude-code-router) in front of a local server. That is **not**
true for this llama.cpp build: b9960's `llama-server` implements the Anthropic
Messages API directly. Verified on this machine:

- `POST /v1/messages` returns real Anthropic-shaped responses
  (`type: "message"`, content blocks, `stop_reason`, `usage`)
- `tool_use` blocks work — the 9B correctly emitted a tool call and
  `stop_reason: "tool_use"`, which is what Claude Code lives on
- `POST /v1/messages/count_tokens` exists too

So `ANTHROPIC_BASE_URL` points straight at llama-server. If you ever downgrade
llama.cpp, re-check before trusting it — a 404 means no Anthropic support and
you're back to needing a proxy:

```sh
curl -s -X POST 127.0.0.1:8080/v1/messages -H 'content-type: application/json' \
  -d '{"model":"qwen-9b","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```

### Why these models don't use their own chat template

Every preset points `chat-template-file` at a copy in `templates/`, because the
template baked into these GGUFs makes Claude Code fail on **every** request,
before a single token is generated:

```
API Error: 400 Unable to generate parser for this template. Automatic parser
generation failed: ... Jinja Exception: System message must be at the beginning.
```

The template rejects any system message that isn't the first, and Claude Code
(checked in 2.1.210) sends exactly that: the main prompt goes in the top-level
`system` field — which `llama-server` maps to `messages[0]` — and a *second*,
system-role message is appended to the **end** of `messages` (the "Available
agent types for the Agent tool" block). That trailing one is not first, so the
template raises and llama.cpp turns the exception into the 400 above.

The error names the template, not the message that tripped it, which makes it
read like a llama.cpp or model bug. It's neither: nothing is wrong with the
build, and the same model answers fine over `curl` — plain requests just never
have a second system message. Worth knowing before re-quantizing anything.

So `templates/` holds each model's own template with **one line changed**: a
non-first system message renders in place as its own ChatML system turn instead
of raising. Content and ordering are preserved, the leading system message is
still folded into the tools block as before, and tool calls are unaffected
(verified: `stop_reason: "tool_use"` with correctly parsed arguments). Both 27B
presets share one file — the two GGUFs carry the same template.

These are **copies**, so unlike `hf-repo` they don't track the model: if a repo
ever ships a new template, this one silently stays behind. To re-derive, print
what the GGUF actually carries (no `--chat-template-file`, so it reports its
own), then re-apply the one-line change:

```sh
llama-server -m <model.gguf> --port 8099 &
curl -s 127.0.0.1:8099/props \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["chat_template"])'
```

## Performance and limits

**Every model is selectable in `/model`; only `qwen-9b` has the context to
drive Claude Code.** The picker lists all three because the router advertises
all three. Both 27B presets run at `ctx-size 8192`, and Claude Code's system
prompt plus tool definitions exceed that before you type anything, so picking
one overflows context immediately. Raising their context isn't an option
either: the 27B already needs ~12 GB of the 16 GB for weights alone. They're
for `./chat.sh`.

On the 9B, expect ~18 t/s generation, and tool-calling accuracy below a
frontier model's — malformed calls and loops on non-trivial tasks are common.

## Notes

- **Claude Code only shows models whose id starts with `claude` or
  `anthropic`.** Its `/model` picker fetches `GET /v1/models` from
  `ANTHROPIC_BASE_URL` and filters the result on `/^(claude|anthropic)/i` —
  hardcoded, with no env var or setting to turn it off (checked in 2.1.210). A
  preset called `qwen-9b` is therefore dropped silently. So `serve.sh`
  advertises each section as `claude-<name>` and passes the bare name to
  `--alias`, which keeps it routable. One model, two names: `/model` sees
  `claude-qwen-9b`, while `./chat.sh qwen-9b`, the OpenAI endpoint and
  `"model": "qwen-9b"` over curl are all unaffected. Claude Code caches what it
  discovers in `~/.claude/cache/gateway-models.json`, keyed by base URL — worth
  knowing if the picker ever looks stale.
- **`serve.sh` rewrites `models.ini` before starting it.** Otherwise the router
  advertises the whole llama.cpp cache next to your presets and `/model` lists
  each model twice, with no flag to disable it in b9960. Suppressing it means
  pointing the cache scan at an empty dir, which in turn rules out `hf-repo`
  (it would re-download into that empty dir) — so `serve.sh` resolves each
  `hf-repo` to the file it already refers to and passes absolute paths.
  Resolution is redone every launch, so it can't pin a stale revision.
- **`serve.sh` can't download.** Because of the above, a preset must already be
  in the cache. If it isn't, `serve.sh` tells you which and exits — run
  `./chat.sh <name>` once to fetch it. `chat.sh` still uses `hf-repo` directly.
- **Args passed to `serve.sh` override every preset.** They're forwarded to the
  router, which applies them to each model instance it spawns — and they *win*
  over `models.ini`. `./serve.sh --no-webui` is fine (the router keeps it to
  itself), but `./serve.sh --ctx-size 65536` silently gives the 27B a 64K
  context too, and it will OOM. Per-model settings belong in `models.ini`.
- **The wired-memory limit resets on reboot.** Both scripts re-raise it via
  `sudo sysctl iogpu.wired_limit_mb` when needed. It's a cap, not a
  reservation, so a raised limit costs nothing while only the 9B is loaded.
  Close PyCharm & co. before loading a 27B.
- **`--models-max 1` in `serve.sh` is load-bearing.** The default is 4; on
  16 GB, letting the router keep two of these resident at once will OOM.
- **INI keys must be real llama.cpp long flags** — the router refuses to start
  on an unknown key. Use `n-gpu-layers`, not `ngl` (llama-cli only takes the
  short `-ngl`). Two keys are special. `wired-limit-mb` is a macOS sysctl
  rather than anything llama.cpp knows about: both scripts read it and strip it
  before launching. They strip that exact spelling and nothing else, so a typo
  reaches llama.cpp and is rejected by name instead of quietly leaving the cap
  where it was. `chat-template-file` is a real flag and reaches llama.cpp as
  written, but its *value* is rewritten: a relative path resolves against
  `models.ini`'s directory, so the presets stay portable and both scripts work
  from any CWD. An absolute path is left alone.
