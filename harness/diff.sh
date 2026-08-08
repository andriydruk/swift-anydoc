#!/usr/bin/env bash
# Differential harness: the Rust anydoc CLI is the executable specification;
# swift-anydoc must produce byte-identical Markdown (and matching error
# classes) for every input it claims to support.
#
# usage: harness/diff.sh <rust-convert-binary> <dir-or-file...>
# Compares only formats the Swift port implements (see IMPLEMENTED below).
set -u

RUST_BIN="$1"; shift
SWIFT_BIN="$(dirname "$0")/../.build/debug/anydoc-cli"
IMPLEMENTED="csv docx pptx pptm ppsx ppsm"

identical=0 divergent=0 errors_matched=0 errors_diverged=0

check() {
    local f="$1" ext="${1##*.}"
    case " $IMPLEMENTED " in *" $ext "*) ;; *) return ;; esac
    local rust_out swift_out rust_rc swift_rc
    rust_out=$("$RUST_BIN" "$f" 2>/dev/null); rust_rc=$?
    swift_out=$("$SWIFT_BIN" "$f" 2>/dev/null); swift_rc=$?
    if [ $rust_rc -ne 0 ] || [ $swift_rc -ne 0 ]; then
        if [ $rust_rc -ne 0 ] && [ $swift_rc -ne 0 ]; then
            errors_matched=$((errors_matched + 1))
        else
            errors_diverged=$((errors_diverged + 1))
            echo "ERROR-CLASS DIVERGES: $f (rust=$rust_rc swift=$swift_rc)"
        fi
        return
    fi
    if [ "$rust_out" = "$swift_out" ]; then
        identical=$((identical + 1))
    else
        divergent=$((divergent + 1))
        echo "DIVERGES: $f"
        diff <(printf '%s' "$rust_out") <(printf '%s' "$swift_out") | head -10
    fi
}

for target in "$@"; do
    if [ -d "$target" ]; then
        while IFS= read -r -d '' f; do check "$f"; done \
            < <(find "$target" -type f -print0 | sort -z)
    else
        check "$target"
    fi
done

echo "identical=$identical divergent=$divergent errors_matched=$errors_matched errors_diverged=$errors_diverged"
[ "$divergent" -eq 0 ] && [ "$errors_diverged" -eq 0 ]
