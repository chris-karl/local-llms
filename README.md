# local-llms

Local LLMs, for two jobs:

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
| `serve.sh`      | `llama-server` in router mode, for Claude Code (behind `router-shim.sh`).               |
| `router-shim.sh`| Sanitizes tool schemas so llama.cpp's tool grammar fits; `serve.sh` runs it. See below. |
| `claude-local/` | Runs Claude Code against the router, starting and sharing one; plus install/uninstall.  |
| `templates/`    | Chat templates for the presets whose built-in one won't drive Claude Code — see below.  |

## CLI chat

Run it bare and pick from a menu:

```
$ ./chat.sh
Available models:

  1) qwen-35b   UD-IQ2_M   48K ctx   text
  2) ...

Choose [1-N, q to quit]:
```

The list is one row per preset in `models.ini` — name, quant, context, and
text-or-images — built on the fly, so it tracks the file and needs no edits here.

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

It opens a model menu — the Claude Code-capable presets from `models.ini` (the
small-context chat ones are left out) — and once you pick one it starts a router
(`serve.sh`) in the background if none is listening, then launches Claude Code
against it. Skip the menu with `ANTHROPIC_MODEL=claude-<name> claude-local`.

**The picked model runs the whole session.** Claude Code's main slot and its
background "haiku" slot (titles, summaries) both use it, so the one resident
model (`--models-max 1`) never thrashes between two. `/model` is scoped to just
that model — to change models, quit and relaunch. (The `claude-` prefix on the
ids is still not cosmetic; see the notes.)

`claude-local.sh` only sets env vars for its own process, so a plain `claude`
in any other terminal still uses the real Anthropic API.

### One router, shared by every terminal

These models are far too big to load twice, so there is only ever one router
and every `claude-local` shares it. It is refcounted rather than owned: the
first one starts it, each later one joins in milliseconds, and it is stopped
once the **last** one exits — not when the one that started it does. So closing
the window you opened first leaves the router up for the others. Sessions that
end badly count the same: the bookkeeping is a directory of pid files, swept
every few seconds by the process that owns the router, so a `kill -9`'d session
drops out of it exactly like a clean exit does.

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

### No translation proxy, one thin shim

The usual advice is that Claude Code needs an Anthropic→OpenAI *translation*
proxy (LiteLLM, claude-code-router) in front of a local server. That is **not**
true for this llama.cpp build: b9960's `llama-server` implements the Anthropic
Messages API directly. Verified:

- `POST /v1/messages` returns real Anthropic-shaped responses
  (`type: "message"`, content blocks, `stop_reason`, `usage`)
- `tool_use` blocks work — the models here correctly emit a tool call and
  `stop_reason: "tool_use"`, which is what Claude Code lives on
- `POST /v1/messages/count_tokens` exists too

So nothing translates formats. If you ever downgrade llama.cpp, re-check before
trusting it — a 404 means no Anthropic support and you're back to needing a
translation proxy:

```sh
curl -s -X POST 127.0.0.1:8080/v1/messages -H 'content-type: application/json' \
  -d '{"model":"qwen-35b","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```

There is one thin local shim in the path, though. `serve.sh` runs
`router-shim.sh` on `$PORT` with llama-server on a private port behind it. It is
**not** a translation proxy: it forwards the Anthropic API unchanged, streaming
and all, and only edits one thing — it strips JSON-Schema *value* constraints
(`pattern`, `format`, `min*`/`max*`, `propertyNames`, …) out of tool definitions
on the way through. llama.cpp compiles those into a grammar that forces
tool-call arguments to match, and across Claude Code's full ~27-tool suite the
combined grammar overflows its rule limit, so **gpt-oss and devstral** otherwise
fail with `400 … failed to parse grammar` — and neither the stable nor the HEAD
llama.cpp build fixes it, nor is there a flag. Dropping the value constraints
keeps the grammar small; a tool's name, description and parameter structure are
untouched, so tool calls still work. The Qwen presets don't need it (their
format doesn't grammar-constrain arguments), but it's harmless to them and
always in front.

The shim is plain shell: `socat` forks a handler per connection, `jq` strips the
schemas, `curl` relays to llama-server. So it leans on two small tools beyond
llama.cpp and the shell — **`jq`** (ships with recent macOS) and **`socat`**
(`brew install socat`) — but no language runtime.

### Chat templates and Claude Code

Every Qwen3.6 preset points `chat-template-file` at a copy in `templates/`,
because the template baked into those GGUFs makes Claude Code fail on **every**
request, before a single token is generated:

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

The error names the template, not the message that tripped it, so it reads like
a llama.cpp or model bug. It's neither: the same model answers fine over
`curl` — plain requests just never have a second system message.

So `templates/` holds the model's own template with **one line changed**: a
non-first system message renders in place as its own ChatML system turn instead
of raising. Content and ordering are preserved, the leading system message is
still folded into the tools block as before, and tool calls are unaffected
(verified: `stop_reason: "tool_use"` with correctly parsed arguments). The
Qwen3.6 presets share the one file `templates/qwen3.6.jinja`: the official
Qwen3.6 repos ship a byte-identical template across the 27B, the 35B-A3B and
the uncensored finetune.

It is a **copy**, so unlike `hf-repo` it doesn't track the models: if a repo
ever ships a new template, this one silently stays behind. To re-derive, print
what the GGUF actually carries (no `--chat-template-file`, so it reports its
own), then re-apply the one-line change:

```sh
llama-server -m <model.gguf> --port 8099 &
curl -s 127.0.0.1:8099/props | jq -r '.chat_template'
```

A preset that sets no `chat-template-file` uses the template inside its own
GGUF. That works when the built-in both renders a non-first system message
(Claude Code always sends one) and declares the model's tool-call format to
llama.cpp — which the MoE candidates' built-ins do, verified end to end. A
preset pins a copy in `templates/` only when its built-in fails one of those:
the Qwen3.6 template raises on the second system message (above), and the
Devstral GGUF here carries a minimal template with no tool syntax at all, so it
uses Unsloth's tool-enabled one. Derive and check any new model's template with
the procedure above — a correct `stop_reason: "tool_use"` on a Claude-Code-shaped
request (top-level system, a trailing second system message, and a tool) is the
bar.

## Limits

**Not every preset drives Claude Code**, and each preset's comment in
`models.ini` says whether it does. Two things have to hold. Its context has to
clear Claude Code's system prompt and tool definitions — a few thousand tokens
before you type anything, which is why a small-context chat preset can't. And it
needs a working chat template (see above): a newly added preset still runs under
`./chat.sh`, but won't drive Claude Code until its template is verified — and
pinned, if the built-in falls short. A candidate also has to be downloaded before
the router will start at all — `serve.sh` treats any un-downloaded preset as
fatal — so fetch it once with `./chat.sh <name>` first, or drop the preset.

The 2-bit presets (UD-IQ2_M) trade accuracy for fit: coding and tool-calling
accuracy sit below the same models at 4-bit and up, the price of a large model
plus tens of thousands of tokens of context in this wired budget. They need the
wired cap raised to fit at all (see the notes), so the first launch asks for
`sudo`. `gpt-oss` and `devstral` additionally rely on `router-shim.sh` (above)
for Claude Code's tool suite, which `serve.sh` starts for you.

Expect the first turn of a session to be slow whichever preset you pick: it
prefills Claude Code's whole system prompt and tool suite (~20K tokens) before
the first token — tens of seconds on the MoE presets, longer on the dense ones —
after which llama.cpp reuses the cached prefix and later turns are quicker.

## Notes

- **Claude Code only shows models whose id starts with `claude` or
  `anthropic`.** Its `/model` picker fetches `GET /v1/models` and filters on
  `/^(claude|anthropic)/i` — hardcoded, no override (checked in 2.1.210), so a
  bare `qwen-35b` is dropped silently. `serve.sh` advertises each section as
  `claude-<name>` but passes the bare name to `--alias` to keep it routable:
  `/model` sees `claude-qwen-35b`, while `./chat.sh qwen-35b`, the OpenAI
  endpoint and `"model": "qwen-35b"` over curl are unaffected. Discovered models
  are cached in `~/.claude/cache/gateway-models.json`, keyed by base URL — worth
  knowing if the picker ever looks stale.
- **`serve.sh` rewrites `models.ini` before starting it.** Otherwise the router
  advertises the whole llama.cpp cache alongside your presets and `/model` lists
  each model twice (no flag disables this in b9960). Suppressing that scan rules
  out `hf-repo` (it would re-download into the empty scan dir), so `serve.sh`
  resolves each `hf-repo` to its cached file and passes absolute paths — redone
  every launch, so it can't pin a stale revision.
- **`serve.sh` can't download.** Because of the above, a preset must already be
  in the cache; if it isn't, `serve.sh` names it and exits — run `./chat.sh
  <name>` once to fetch it. `chat.sh` still uses `hf-repo` directly.
- **Args passed to `serve.sh` override every preset.** The router forwards them
  to every model instance it spawns, where they *win* over `models.ini`.
  `./serve.sh --no-webui` is fine (the router keeps it), but `./serve.sh
  --ctx-size 65536` forces that context on every model, and one sized to a
  smaller budget will OOM. Per-model settings belong in `models.ini`.
- **The auto-started router is detached from the terminal that started it.** It
  must outlive that window closing and ignore a Ctrl+C meant for Claude Code (a
  tty sends SIGINT to the whole foreground group, which `llama-server` acts on).
  So `claude-local` starts it under `nohup` in its own process group (`setsid`,
  or `set -m` as a fallback), stdin on `/dev/null`, output in `router.log`
  alongside the pid files under `$TMPDIR/local_LLMs.<uid>/claude-local.<port>/`.
  That log is where a router that won't start says why; `claude-local` prints
  its tail when the router doesn't come up.
- **`claude-local` runs `serve.sh --preflight` first, in your terminal.**
  Anything needing a human must happen before the router detaches: the `sudo`
  for the wired-limit raise prompts on `/dev/tty`, which a background group may
  not read, and a missing download should surface where you're looking, not in a
  log. `--preflight` does just that — resolve presets, report missing downloads,
  raise the cap — then exits without serving.
- **The wired-memory limit is an Apple Silicon thing, and resets on reboot.**
  CPU and GPU share one memory pool and the GPU may only wire down part of it,
  so a preset asking for more than the current cap gets it raised via `sudo
  sysctl iogpu.wired_limit_mb`. It's a cap, not a reservation, so it costs
  nothing until a model fills it — but close memory-hungry apps before loading
  one that wants most of it. Both scripts skip the raise where the sysctl is
  absent or the cap is already high enough, so a machine with memory to spare is
  never asked for sudo.
- **`parallel = 1` is a memory knob, not a request limit.** Qwen3.6's hybrid
  attention replaces most of the KV cache with recurrent state, allocated per
  slot, and the slot count defaults to 4. One Claude Code session uses one slot;
  capping it there avoids three idle copies of that state. Extra requests queue
  and complete; nothing fails.
- **`--models-max 1` in `serve.sh` is load-bearing.** The default is 4; letting
  the router keep two of these models resident at once will OOM a machine sized
  for one.
- **INI keys must be real llama.cpp long flags** — the router refuses to start
  on an unknown key. Use `n-gpu-layers`, not `ngl` (llama-cli only takes the
  short `-ngl`). Two keys are special. `wired-limit-mb` is a macOS sysctl, not
  anything llama.cpp knows: both scripts read it and strip that exact spelling
  before launching, so a typo reaches llama.cpp and is rejected by name instead
  of silently leaving the cap unchanged. `chat-template-file` reaches llama.cpp
  as written, but its *value* is rewritten — a relative path resolves against
  `models.ini`'s directory so presets stay portable from any CWD; an absolute
  path is left alone.
