#!/bin/sh
# Interactive CLI chat. No server, no port.
#
#   ./chat.sh                      pick a model from a menu
#   ./chat.sh qwen-35b             launch it directly
#   ./chat.sh qwen-35b --ctx-size 4096   extra args pass through and win
#
# Also the download path: llama-cli --hf-repo fetches on first use, and
# serve.sh needs models present already.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INI="$DIR/models.ini"

presets() { awk -F'[][]' '/^[ \t]*\[/ { print $2 }' "$INI"; }

# name <tab> quant <tab> context <tab> modality, one row per models.ini section
preset_rows() {
    awk '
        function flush() {
            if (sec == "") return
            quant = repo; sub(/.*:/, "", quant); if (quant == "") quant = "?"
            if (ctx + 0 >= 1024) ctxh = sprintf("%dK", ctx / 1024); else ctxh = (ctx == "" ? "?" : ctx)
            printf "%s\t%s\t%s ctx\t%s\n", sec, quant, ctxh, (nomm != "" ? "text" : "images")
            sec = ""; repo = ""; ctx = ""; nomm = ""
        }
        /^[ \t]*#/ { next }
        /^[ \t]*\[/ { flush(); s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s; next }
        sec == "" || !/=/ { next }
        {
            k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == "hf-repo" || k == "model") repo = v
            else if (k == "ctx-size") ctx = v
            else if (k == "no-mmproj") nomm = "y"
        }
        END { flush() }
    ' "$INI"
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

MENU=$(mktemp) || exit 1
trap 'rm -f "$MENU"' EXIT
preset_rows | while IFS="$(printf '\t')" read -r n q c m; do
    printf '%s\t%-16s %-8s %-9s %s\n' "$n" "$n" "$q" "$c" "$m"
done > "$MENU"

if [ ! -s "$MENU" ]; then
    echo "no models: $INI has no sections" >&2
    exit 1
fi

MODEL=${1:-}
if [ -n "$MODEL" ]; then
    shift
else
    echo "Available models:"
    echo
    i=0
    while IFS="$(printf '\t')" read -r _ label; do
        i=$((i + 1))
        printf '  %d) %s\n' "$i" "$label"
    done < "$MENU"
    echo
    # Read stdin rather than /dev/tty, so "echo 2 | ./chat.sh" works too.
    printf 'Choose [1-%d, q to quit]: ' "$i"
    if ! IFS= read -r choice; then
        echo
        echo "no selection" >&2
        exit 1
    fi
    case "$choice" in
        q | Q | "") echo "nothing selected"; exit 0 ;;
        *[!0-9]*) echo "not a number: $choice" >&2; exit 1 ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
        echo "out of range: $choice" >&2
        exit 1
    fi
    MODEL=$(cut -f1 "$MENU" | sed -n "${choice}p")
    echo
fi

if ! presets | grep -qx "$MODEL"; then
    echo "no such model: $MODEL" >&2
    echo "known: $(presets | tr '\n' ' ')" >&2
    exit 1
fi

# Raise the GPU-wired cap if this preset asks for more than is allowed now.
NEED=$(awk -v want="$MODEL" '
    /^[ \t]*#/ { next }
    /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (s == want); next }
    !insec || !/=/ { next }
    {
        k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
        if (k != "wired-limit-mb") next
        v = $0; sub(/^[^=]*=/, "", v)
        print v + 0; exit
    }
' "$INI")
raise_wired_limit "${NEED:-0}"

# "no-mmap = true" takes no value on the command line, so valueless --no-*
# flags are emitted bare.
ARGS=$(awk -v want="$MODEL" -v dir="$DIR" '
    /^[ \t]*#/ { next }
    /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (s == want); next }
    !insec || !/=/ { next }
    {
        k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
        v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (k == "") next
        # Ours, not a llama.cpp flag -- llama-cli would reject it.
        if (k == "wired-limit-mb") next
        # Written relative to models.ini; llama-cli would resolve it against
        # the CWD instead, and ./chat.sh runs from anywhere.
        if (k == "chat-template-file" && v !~ /^\//) v = dir "/" v
        if (k ~ /^no-/ && (v == "" || v == "true" || v == "1")) { printf "--%s\n", k; next }
        printf "--%s\n%s\n", k, v
    }
' "$INI")

# Prepend, so an explicit "./chat.sh qwen-35b --ctx-size 4096" still wins:
# llama.cpp takes the last occurrence of a repeated flag.
QUOTED=$(printf '%s\n' "$ARGS" | sed -e "s/'/'\\\\''/g" -e "s/^/'/" -e "s/\$/'/" | tr '\n' ' ')
eval "set -- $QUOTED \"\$@\""

exec llama-cli "$@"
