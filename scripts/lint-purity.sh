#!/usr/bin/env bash
# The dependency gate: nothing under Sources/AnyDoc may import Foundation
# (any flavor) or an Apple closed-source framework, no escape hatches, and
# Package.swift may fetch nothing. Tests and tooling may use Foundation; the
# library may not.
#
# Linking a *system* library is a separate question from fetching a package,
# and the two were conflated until zlib landed. `CZlib` is permitted by name
# below; anything else needs a decision, not a silent pass.
set -u
banned='^[[:space:]]*import[[:space:]]+(Foundation|FoundationEssentials|FoundationXML|FoundationNetworking|Compression|PDFKit|CoreGraphics|AppKit|UIKit|CryptoKit)([[:space:]]|$)'
escape='@_silgen_name|dlopen|NSClassFromString'
fail=0
if grep -rnE "$banned" Sources/AnyDoc --include='*.swift'; then
    echo "FAIL: banned import in Sources/AnyDoc" >&2
    fail=1
fi
if grep -rnE "$escape" Sources/AnyDoc --include='*.swift'; then
    echo "FAIL: escape hatch in Sources/AnyDoc" >&2
    fail=1
fi
# Comments are stripped first: this checks what the manifest *declares*, not
# what its prose mentions. The check fired on a comment containing the literal
# `.package(` the first time zlib was linked, which is the wrong kind of
# failure — a gate that trips on documentation teaches people to stop writing
# it.
manifest=$(sed 's,//.*,,' Package.swift)
if printf '%s' "$manifest" | grep -qE '\.package\('; then
    echo "FAIL: Package.swift declares a fetched dependency" >&2
    fail=1
fi

# System libraries are allowed and enumerated. `CZlib` links the platform
# zlib — present on macOS, the iOS SDK and every mainstream Linux — which is
# a link, not a fetch. Anything else added here should be a deliberate
# decision, so the gate names what it permits.
unexpected=$(printf '%s' "$manifest" | grep -oE '\.systemLibrary\(name: "[A-Za-z0-9_]+"' \
    | grep -vE '"CZlib"' || true)
if [ -n "$unexpected" ]; then
    echo "FAIL: unexpected system library: $unexpected" >&2
    fail=1
fi
[ "$fail" -eq 0 ] && echo "purity lint: OK"
exit "$fail"
