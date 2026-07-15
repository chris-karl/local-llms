#!/bin/sh
# Run Claude Code against the local router from serve.sh, which must already
# be running. Everything is scoped to this one process, so a plain "claude" in
# any other terminal still talks to the real Anthropic API.
#
#   ./claude-local.sh                  start on the default model
#   ANTHROPIC_MODEL=claude-qwen-27b ./claude-local.sh
#
# ./install.sh puts this on your PATH as "claude-local", usable from any
# directory. Once inside, /model lists every section from models.ini.
set -eu

PORT=${PORT:-8080}
BASE="http://127.0.0.1:${PORT}"

if ! curl -sf -o /dev/null "$BASE/health"; then
    echo "No router on $BASE -- start it first with:  ./serve.sh" >&2
    exit 1
fi

export ANTHROPIC_BASE_URL="$BASE"

# llama-server ignores auth unless --api-key is set, but Claude Code needs
# some credential present or it falls back to your real login.
export ANTHROPIC_AUTH_TOKEN="local"

# Populates /model from the router's /v1/models. Needs Claude Code >= 2.1.129.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

# qwen-9b is the only one with the context to hold Claude Code's system
# prompt, so it stays the default; the 27B presets overflow it (see README).
# The haiku slot is used for background chores (titles, summaries) and must
# also resolve to a local model, or those requests 404 against the router.
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-qwen-9b}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-qwen-9b}"

exec claude "$@"
