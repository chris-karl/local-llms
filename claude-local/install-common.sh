#!/bin/sh
# Shared by install.sh and uninstall.sh: the PATH-block markers (they MUST match
# between the two, or uninstall can't find what install wrote), the --help
# extractor, and where the symlink lives. Sourced after $DIR is set, not run.

MARK_START='# >>> claude-local >>>'
MARK_END='# <<< claude-local <<<'

TARGET="$DIR/claude-local.sh"
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
LINK="$BIN_DIR/claude-local"

# Print the caller's own header (--help) or reject an unknown option. $0 is the
# invoked script, not this file, so it prints install.sh's or uninstall.sh's
# head -- the comment block down to the first line of actual code.
parse_opts() {
    for _arg in "$@"; do
        case $_arg in
            -h | --help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | cut -c3-; exit 0 ;;
            *) echo "unknown option: $_arg (try --help)" >&2; exit 2 ;;
        esac
    done
}
