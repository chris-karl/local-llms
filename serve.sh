#!/bin/sh
# Router server exposing every model in models.ini. Serves the Anthropic
# Messages API on /v1/messages natively, so Claude Code needs no proxy, and
# the OpenAI API on /v1/chat/completions for everything else.
#
#   ./serve.sh                 listen on 127.0.0.1:8080
#   PORT=9000 ./serve.sh       listen elsewhere
#   ./serve.sh --no-webui      API only, no browser UI
#   ./serve.sh --preflight     do the checks that need a terminal, don't serve
#
# Running this by hand is optional: ./claude-local/claude-local.sh starts one
# itself when nothing is listening yet, and stops it when the last one exits.
# A router started here is left alone by claude-local -- it stays yours.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INI="$DIR/models.ini"
PORT=${PORT:-8080}
HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# Ours, not llama.cpp's, so it has to come out of what is forwarded below.
# Rotating through "$@" keeps every other argument as given, spaces and all.
PREFLIGHT=""
_argc=$#
while [ "$_argc" -gt 0 ]; do
    _argc=$((_argc - 1))
    _arg=$1
    shift
    case $_arg in
        --preflight) PREFLIGHT=1 ;;
        *) set -- "$@" "$_arg" ;;
    esac
done

# A fixed path, not mktemp -d: this script exec's into llama-server, so no exit
# trap can ever run to clean up. Contents derive wholly from models.ini, so
# concurrent servers can share it.
TMP="${TMPDIR:-/tmp}/local_LLMs.$(id -u)"
mkdir -p "$TMP" || exit 1

presets() { awk -F'[][]' '/^[ \t]*\[/ { print $2 }' "$INI"; }

# Value of one key inside one section, empty if absent.
key_of() {
    awk -v want="$1" -v key="$2" '
        /^[ \t]*#/ { next }
        /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (s == want); next }
        !insec || !/=/ { next }
        {
            k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == key) { print v; exit }
        }
    ' "$INI"
}

# "owner/repo:QUANT" -> the .gguf it currently resolves to, mirroring
# --hf-repo. Reading refs/main each launch is what keeps this off a stale
# revision.
resolve_gguf() {
    _spec=$1
    _repo=${_spec%:*}
    _quant=${_spec##*:}
    _dir="$HUB/models--$(echo "${_repo%%/*}" | tr -d '\n')--$(echo "${_repo#*/}" | tr -d '\n')"
    [ -d "$_dir" ] || return 1
    _sha=$(cat "$_dir/refs/main" 2>/dev/null) || return 1
    [ -n "$_sha" ] || return 1
    _snap="$_dir/snapshots/$_sha"
    [ -d "$_snap" ] || return 1
    find "$_snap" -maxdepth 1 -name "*-$_quant.gguf" ! -name "mmproj*" 2>/dev/null | head -1
}

# The vision projector next to it, if the repo ships one.
resolve_mmproj() {
    _g=$1
    find "$(dirname "$_g")" -maxdepth 1 -name "mmproj*.gguf" 2>/dev/null | head -1
}

# Make sure the GPU may wire down at least $1 MB, where that is a thing at all.
#
# Apple Silicon shares one pool of memory between CPU and GPU and caps how much
# of it the GPU may wire down, so a big model needs the cap raised. It's a cap,
# not a reservation, so raising it costs nothing at idle; resets on reboot.
# Nothing else has this knob -- a discrete GPU has its own VRAM -- so a sysctl
# that isn't there means there is nothing to do, not that anything is wrong.
raise_wired_limit() {
    _need=$1
    [ "$_need" -gt 0 ] || return 0

    _current=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null) || return 0
    case $_current in '' | *[!0-9]*) return 0 ;; esac

    # 0 means "the kernel default", not "no memory": roughly three quarters of
    # installed RAM. Measuring against that is what stops a machine with RAM to
    # spare from having its cap *lowered* to a preset's number.
    if [ "$_current" -eq 0 ]; then
        _total=$(sysctl -n hw.memsize 2>/dev/null) || return 0
        _current=$((_total / 1048576 * 3 / 4))
    fi

    [ "$_current" -lt "$_need" ] || return 0
    echo "Raising GPU wired limit to ${_need} MB (sudo)..."
    sudo sysctl iogpu.wired_limit_mb="$_need" || exit 1
}

# section <tab> gguf <tab> mmproj-or-empty
MAP="$TMP/map"
: > "$MAP"
MISSING=""
for m in $(presets); do
    spec=$(key_of "$m" "hf-repo")
    if [ -z "$spec" ]; then
        # Already an explicit path (or no model at all) -- leave it alone.
        continue
    fi
    if ! gguf=$(resolve_gguf "$spec") || [ -z "$gguf" ]; then
        MISSING="$MISSING  $m ($spec)
"
        continue
    fi
    mm=""
    if [ -z "$(key_of "$m" "no-mmproj")" ]; then
        mm=$(resolve_mmproj "$gguf")
    fi
    printf '%s\t%s\t%s\n' "$m" "$gguf" "$mm" >> "$MAP"
done

if [ -n "$MISSING" ]; then
    echo "not downloaded yet:" >&2
    printf '%s' "$MISSING" >&2
    echo "fetch each once with:  ./chat.sh <model>    (that path still uses hf-repo)" >&2
    exit 1
fi

# Rewrite hf-repo lines into resolved paths and section names into
# claude-prefixed ids; everything else verbatim. Runs fresh on every launch,
# so models.ini stays portable and this can't go stale.
RESOLVED="$TMP/models.resolved.ini"
awk -v mapfile="$MAP" -v dir="$DIR" '
    BEGIN {
        FS = "\t"
        while ((getline line < mapfile) > 0) {
            split(line, a, "\t")
            gguf[a[1]] = a[2]; mmproj[a[1]] = a[3]
        }
        FS = "\n"
    }
    # Claude Code hard-filters gateway /v1/models to ids matching
    # ^(claude|anthropic), with no way to turn it off, so advertise the
    # prefixed id and keep the bare name routable via --alias. See README.
    /^[ \t]*\[/ {
        s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s
        if (tolower(sec) ~ /^(claude|anthropic)/) print "[" sec "]"
        else printf "[claude-%s]\nalias = %s\n", sec, sec
        next
    }
    {
        k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
        # Ours, not a llama.cpp flag -- the router refuses to start on it.
        if (k == "wired-limit-mb") next
        if (k == "hf-repo" && sec in gguf) {
            printf "model = %s\n", gguf[sec]
            if (mmproj[sec] != "") printf "mmproj = %s\n", mmproj[sec]
            next
        }
        # Written relative to models.ini; the router would resolve it against
        # its own CWD instead.
        if (k == "chat-template-file") {
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
            printf "chat-template-file = %s\n", (v ~ /^\// ? v : dir "/" v)
            next
        }
        print
    }
' "$INI" > "$RESOLVED"

# The router loads on demand, so ask for the largest any preset wants.
NEED=$(awk '
    /^[ \t]*#/ { next }
    !/=/ { next }
    {
        k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
        if (k != "wired-limit-mb") next
        v = $0; sub(/^[^=]*=/, "", v)
        if (v + 0 > m) m = v + 0
    }
    END { print m + 0 }
' "$INI")
raise_wired_limit "$NEED"

# Everything above wanted a terminal: missing downloads are reported there, and
# sudo prompts on /dev/tty, which a detached router has no claim on. So
# claude-local runs this much in your window before detaching the real one.
if [ -n "$PREFLIGHT" ]; then
    exit 0
fi

echo "Serving $(presets | wc -l | tr -d ' ') models from models.ini on 127.0.0.1:${PORT}"

# HF_HOME points at an empty dir to stop the router advertising the whole
# llama.cpp cache alongside the presets, listing each model twice in /model
# (no flag for that in b9960) -- which is also why the presets carry absolute
# paths by now. --models-max 1 is load-bearing: on a machine sized for exactly
# one of these models, the default of 4 would OOM on a /model switch.
mkdir -p "$TMP/emptycache"
HF_HOME="$TMP/emptycache" exec llama-server \
    --models-preset "$RESOLVED" \
    --models-max 1 \
    --host 127.0.0.1 \
    --port "$PORT" \
    "$@"
