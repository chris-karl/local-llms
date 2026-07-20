# local-llms

Local Qwen models, for two jobs:

- **CLI chat, no server** — `./chat.sh qwen-35b`
- **A local backend for Claude Code** — `./claude-local/claude-local.sh`

`models.ini` is the single source of truth for both. Add a model once there and
it shows up in `./chat.sh` and in Claude Code's `/model` picker.

**The presets are sized for unified memory** — an Apple Silicon Mac, where CPU
and GPU share one pool of RAM. That is why `n-gpu-layers = 999` puts every
layer on the GPU: there is no separate VRAM budget to fit them into, so the
figures in `models.ini` are against total system RAM. The scripts hold nothing
macOS-only beyond the wired-memory cap, which they skip where it doesn't exist,
so a Linux or discrete-GPU machine runs them — but the sizing doesn't carry
over. `qwen-35b`'s ~12 GB is a VRAM requirement there, and splitting a model
across GPU and CPU means lowering `n-gpu-layers` rather than pinning it to 999.

## Files

| File            | What it does                                                                            |
|-----------------|-----------------------------------------------------------------------------------------|
| `models.ini`    | Every model + its tuned flags. Edit this, not the scripts.                              |
| `chat.sh`       | Interactive `llama-cli` chat, with a model picker. No server, no port.                  |
| `serve.sh`      | `llama-server` in router mode, for Claude Code.                                         |
| `claude-local/` | Runs Claude Code against the router, starting and sharing one; plus install/uninstall.  |
| `templates/`    | Each model's chat template, patched. Claude Code doesn't work without this — see below. |

## CLI chat

Run it bare and pick from a menu:

```
$ ./chat.sh
Available models:

  1) qwen-35b             UD-IQ2_M   48K ctx   text
  2) qwen-27b             UD-IQ2_M   48K ctx   text
  3) qwen-27b-uncensored  IQ3_XS     8K ctx    images

Choose [1-3, q to quit]:
```

Or skip the menu:

```sh
./chat.sh qwen-35b
./chat.sh qwen-35b --ctx-size 4096   # extra args pass through and win
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
./claude-local/claude-local.sh
```

That is the whole command: with nothing listening yet, it starts a router
(`serve.sh`) in the background and waits for it, which takes about a second.

Inside, `/model` lists every model from `models.ini` — as `claude-qwen-35b`,
`claude-qwen-27b`, … — and switches between them live, unloading the old model
before loading the new one. The prefix is not cosmetic; see the notes.

`claude-local.sh` only sets env vars for its own process, so a plain `claude`
in any other terminal still uses the real Anthropic API.

### One router, shared by every terminal

These models are far too big to load twice, so there is only ever one router
and every `claude-local` shares it. It is refcounted rather than owned: the
first one starts it, each later one joins the running one in milliseconds, and
it is stopped once the **last** one exits — not when the one that started it
does.

So closing the window you opened first leaves the router up for the others,
and closing the last one takes it down and gives the model's RAM back.
Sessions that end badly count the same: the bookkeeping is a directory of pid
files, swept every few seconds by the process that owns the router, so a
`kill -9`'d session drops out of it exactly like a clean exit does.

Running `./serve.sh` yourself still works, and what you start stays yours:
`claude-local` uses a router it finds already listening and never stops one it
did not start itself. That is the way to watch the logs live, or to hold a
router up across sessions.

### Using it from anywhere

`claude-local.sh` reaches the router over HTTP and doesn't care where it's run
from, so it works in any project once it's on your PATH:

```sh
./claude-local/install.sh      # symlink -> ~/.local/bin/claude-local
cd ~/some/other/project
claude-local                   # starts or joins the router, as always
```

`install.sh` symlinks rather than copies, so edits here take effect at once —
but moving this repo breaks the link, and re-running it fixes it. If the target
dir isn't on your PATH, it appends a guarded block to the rc file of your login
shell, auto-detected (zsh, bash, ksh, else `~/.profile`); then `. ~/.zshrc`,
or open a new terminal. fish is the exception: it still gets the symlink, but
its config is left alone and you put the dir on your PATH yourself. Install
elsewhere with `BIN_DIR=/usr/local/bin sudo ./claude-local/install.sh`.

`./claude-local/uninstall.sh` is the exact inverse: it drops the symlink, the
PATH block, and the bin dir, leaving no trace. Each step is scoped to what
`install.sh` made — only a link pointing back here, only the marker-delimited
block (a PATH line you wrote yourself isn't matched), and only an empty dir.

### Why there's no proxy here

The usual advice is that Claude Code needs an Anthropic→OpenAI translation
proxy (LiteLLM, claude-code-router) in front of a local server. That is **not**
true for this llama.cpp build: b9960's `llama-server` implements the Anthropic
Messages API directly. Verified:

- `POST /v1/messages` returns real Anthropic-shaped responses
  (`type: "message"`, content blocks, `stop_reason`, `usage`)
- `tool_use` blocks work — the models here correctly emit a tool call and
  `stop_reason: "tool_use"`, which is what Claude Code lives on
- `POST /v1/messages/count_tokens` exists too

So `ANTHROPIC_BASE_URL` points straight at llama-server. If you ever downgrade
llama.cpp, re-check before trusting it — a 404 means no Anthropic support and
you're back to needing a proxy:

```sh
curl -s -X POST 127.0.0.1:8080/v1/messages -H 'content-type: application/json' \
  -d '{"model":"qwen-35b","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
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

So `templates/` holds the model's own template with **one line changed**: a
non-first system message renders in place as its own ChatML system turn instead
of raising. Content and ordering are preserved, the leading system message is
still folded into the tools block as before, and tool calls are unaffected
(verified: `stop_reason: "tool_use"` with correctly parsed arguments). Every
preset shares the one file `templates/qwen3.6.jinja`: the official Qwen3.6
repos ship a byte-identical template for the 27B and the 35B-A3B, and the
uncensored 27B finetune carries the same one.

It is a **copy**, so unlike `hf-repo` it doesn't track the models: if a repo
ever ships a new template, this one silently stays behind. To re-derive, print
what the GGUF actually carries (no `--chat-template-file`, so it reports its
own), then re-apply the one-line change:

```sh
llama-server -m <model.gguf> --port 8099 &
curl -s 127.0.0.1:8099/props \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["chat_template"])'
```

## Limits

**`qwen-35b` and `qwen-27b` drive Claude Code; `qwen-27b-uncensored`
doesn't.** The picker lists all three because the router advertises all three,
but the uncensored preset runs at `ctx-size 8192`, and Claude Code's system
prompt plus tool definitions exceed that before you type anything — picking it
overflows context immediately. It's for `./chat.sh`.

Both Claude Code presets run 2-bit quantizations (UD-IQ2_M) at 48K context:
coding and tool-calling accuracy sit below the same models at 4-bit and up,
which is the trade for fitting a 27–35B model plus that much context into this
wired budget. Both need the wired cap raised to fit at all (see the notes);
the machine's ~12 GiB default is not enough, so the first launch asks for
`sudo`. Verified end to end on a 16 GB M1 Pro: both return a correct
`tool_use` on a Claude-Code-shaped request. Between them, the 35B decodes
several times faster — 3B of its parameters are active per token, and its
mostly linear-attention layers keep the KV cache small, so it has memory to
spare at 48K. The dense 27B is stronger per token but every parameter is
active on every one, so its turns take several times longer and its KV cache
is larger; 48K is its ceiling here, where the 35B has room past it.

## Notes

- **Claude Code only shows models whose id starts with `claude` or
  `anthropic`.** Its `/model` picker fetches `GET /v1/models` from
  `ANTHROPIC_BASE_URL` and filters the result on `/^(claude|anthropic)/i` —
  hardcoded, with no env var or setting to turn it off (checked in 2.1.210). A
  preset called `qwen-35b` is therefore dropped silently. So `serve.sh`
  advertises each section as `claude-<name>` and passes the bare name to
  `--alias`, which keeps it routable. One model, two names: `/model` sees
  `claude-qwen-35b`, while `./chat.sh qwen-35b`, the OpenAI endpoint and
  `"model": "qwen-35b"` over curl are all unaffected. Claude Code caches what it
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
- **The auto-started router is detached from the terminal that started it.** It
  has to outlive that window closing, and ignore a Ctrl+C meant for Claude
  Code — a tty sends SIGINT to every process in the foreground process group,
  and `llama-server` acts on it. So `claude-local` starts it under `nohup`
  (SIGHUP ignored, which survives `exec`), in a process group of its own
  (`setsid` where there is one, otherwise `set -m`, which is how `/bin/sh`
  hands a background job its own group), with stdin on `/dev/null` and its
  output in `router.log` — next to the pid files, under
  `$TMPDIR/local_LLMs.<uid>/claude-local.<port>/`. That log is where a router
  that won't start says why, and `claude-local` prints the tail of it when the
  router doesn't come up.
- **`claude-local` runs `serve.sh --preflight` first, in your terminal.**
  Anything that needs a human has to happen before the router is detached:
  `sudo` prompts on `/dev/tty`, which a background process group may not read
  from, so the wired-limit raise cannot be left to the detached router — and a
  preset that still needs downloading should say so where you are looking,
  rather than in a log file. `--preflight` does exactly that much of
  `serve.sh` — resolve the presets, report missing downloads, raise the cap —
  and exits without serving.
- **The wired-memory limit is an Apple Silicon thing, and resets on reboot.**
  There, CPU and GPU share one pool of memory and the GPU may only wire down
  part of it, so a preset asking for more than the current cap gets it raised
  via `sudo sysctl iogpu.wired_limit_mb`. It's a cap, not a reservation, so a
  raised limit costs nothing until a model actually fills it. Close
  memory-hungry apps before loading a model that wants most of it. Both scripts skip the
  raise where the sysctl doesn't exist, and where the cap is already high
  enough — a machine with memory to spare is never asked for sudo.
- **`parallel = 1` is a memory knob, not a request limit.** Qwen3.6's hybrid
  attention replaces most of the KV cache with recurrent state, which
  llama-server allocates per slot, and its slot count defaults to 4. A single
  Claude Code session uses one slot; capping it there avoids paying for three
  idle copies of that state. Requests beyond the one slot queue and complete;
  nothing fails. (Unsloth also ships MTP variants of these GGUFs for faster
  speculative decoding, but the multi-token-prediction head needs more memory
  than this budget has, and llama-server disables it under pressure anyway, so
  the plain GGUFs are used.)
- **`--models-max 1` in `serve.sh` is load-bearing.** The default is 4; letting
  the router keep two of these models resident at once will OOM a machine sized
  for one.
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
