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

# Pick the model for this session up front, unless one is given via
# ANTHROPIC_MODEL. Only one model is resident (--models-max 1) and Claude Code
# drives two slots -- a main model and a background "haiku" one -- so both run
# the SAME model, chosen here. The picker is then scoped to it (see the base URL
# below and router-shim.sh), so switching means restarting. Menu excludes
# presets whose context is too small for Claude Code's system prompt.
if [ -z "${ANTHROPIC_MODEL:-}" ]; then
    INI="$DIR/../models.ini"
    MIN_CTX=32768   # below this a preset can't hold Claude Code's ~29K prompt
    ROWS=$(awk -v min="$MIN_CTX" '
        function flush() { if (sec != "" && ctx + 0 >= min) printf "%s\t%dK\n", sec, ctx / 1024; sec = ""; ctx = 0 }
        /^[ \t]*#/ { next }
        /^[ \t]*\[/ { flush(); s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s; next }
        sec == "" || !/=/ { next }
        {
            k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
            if (k == "ctx-size") { v = $0; sub(/^[^=]*=/, "", v); gsub(/[ \t]/, "", v); ctx = v }
        }
        END { flush() }
    ' "$INI")
    [ -n "$ROWS" ] || { echo "claude-local: no Claude Code-capable models in $INI" >&2; exit 1; }
    echo "Model for this Claude Code session:"
    echo
    printf '%s\n' "$ROWS" | awk -F'\t' '{ printf "  %d) %-18s %s ctx\n", NR, $1, $2 }'
    echo
    _n=$(printf '%s\n' "$ROWS" | grep -c .)
    printf 'Choose [1-%d, q to quit]: ' "$_n"
    IFS= read -r _choice < /dev/tty || { echo; exit 1; }
    case $_choice in
        q | Q | '') echo "nothing selected"; exit 0 ;;
        *[!0-9]*) echo "not a number: $_choice" >&2; exit 1 ;;
    esac
    { [ "$_choice" -ge 1 ] && [ "$_choice" -le "$_n" ]; } || { echo "out of range: $_choice" >&2; exit 1; }
    ANTHROPIC_MODEL="claude-$(printf '%s\n' "$ROWS" | sed -n "${_choice}p" | cut -f1)"
    echo
fi

# Registers this shell as one of the things keeping the router alive, starting
# one if there is none. "exec claude" below keeps this pid, so the router lives
# exactly as long as the session does, however it ends. PORT is passed rather
# than exported: it is router.sh's business, not claude's.
PORT="$PORT" "$DIR/router.sh" acquire "$$"

export ANTHROPIC_MODEL

# The model is baked into the base URL path (/m/<model>). router-shim.sh strips
# it and filters GET /v1/models down to this one model, so Claude Code's /model
# picker shows only it -- no mid-session switch, restart to change models.
export ANTHROPIC_BASE_URL="$BASE/m/$ANTHROPIC_MODEL"

# llama-server ignores auth unless --api-key is set, but Claude Code needs
# some credential present or it falls back to your real login.
export ANTHROPIC_AUTH_TOKEN="local"

# Populates /model from the router's /v1/models. Needs Claude Code >= 2.1.129.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

# The background "haiku" slot (titles, summaries) runs the same model as the
# main one, so the single resident model (--models-max 1) never thrashes.
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_MODEL"

exec claude "$@"
