#!/bin/sh
# Shared helpers, sourced by chat.sh, serve.sh and claude-local. Not executed on
# its own. presets()/key_of() read the models.ini named by $INI, which the
# caller sets first; raise_wired_limit() needs no INI.

# Section names, one per line -- the model ids.
presets() { awk -F'[][]' '/^[ \t]*\[/ { print $2 }' "$INI"; }

# Value of one key inside one section ($1 = section, $2 = key); empty if absent.
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
