#!/bin/sh
# Run Claude Code against a local model, starting the router if it isn't up.
# Everything is scoped to this one process, so a plain "claude" in any other
# terminal still talks to the real Anthropic API.
#
#   ./claude-local.sh                  start on the default model
#   ANTHROPIC_MODEL=claude-qwen-27b ./claude-local.sh
#
# The router is shared and refcounted: it is stopped once the last claude-local
# exits, not when the one that started it does. See router.sh. One started by
# hand with ./serve.sh is used as-is and never stopped.
#
# ./install.sh puts this on your PATH as "claude-local", usable from any
# directory. Once inside, /model lists every section from models.ini.
set -eu

# Follow the symlink install.sh puts on your PATH, so router.sh and serve.sh
# are found in the checkout rather than next to the link.
SELF=$0
case $SELF in
    */*) ;;
    *) SELF=$(command -v -- "$SELF") ;;
esac
_hops=0
while [ -L "$SELF" ] && [ "$_hops" -lt 16 ]; do
    _link=$(readlink -- "$SELF")
    case $_link in
        /*) SELF=$_link ;;
        *) SELF=$(dirname -- "$SELF")/$_link ;;
    esac
    _hops=$((_hops + 1))
done
DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd)

PORT=${PORT:-8080}
BASE="http://127.0.0.1:${PORT}"

# Registers this shell as one of the things keeping the router alive, starting
# one if there is none. "exec claude" below keeps this pid, so the router lives
# exactly as long as the session does, however it ends. PORT is passed rather
# than exported: it is router.sh's business, not claude's.
PORT="$PORT" "$DIR/router.sh" acquire "$$"

export ANTHROPIC_BASE_URL="$BASE"

# llama-server ignores auth unless --api-key is set, but Claude Code needs
# some credential present or it falls back to your real login.
export ANTHROPIC_AUTH_TOKEN="local"

# Populates /model from the router's /v1/models. Needs Claude Code >= 2.1.129.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

# qwen-35b is the default: it holds Claude Code's system prompt at 48K and
# decodes fastest (3B active parameters), which an agentic loop spends most
# of its time on. qwen-27b trades speed for quality; qwen-27b-uncensored
# overflows its 8K context immediately (see README).
# The haiku slot is used for background chores (titles, summaries) and must
# also resolve to a local model, or those requests 404 against the router.
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-qwen-35b}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-claude-qwen-35b}"

exec claude "$@"
