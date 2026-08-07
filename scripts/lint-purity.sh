#!/usr/bin/env bash
# The zero-dependency gate: nothing under Sources/AnyDoc may import
# Foundation (any flavor) or an Apple closed-source framework, and no escape
# hatches. Tests and tooling may use Foundation; the library may not.
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
deps=$(grep -c 'dependencies:' Package.swift || true)
if grep -qE '\.package\(' Package.swift; then
    echo "FAIL: Package.swift declares an external dependency" >&2
    fail=1
fi
[ "$fail" -eq 0 ] && echo "purity lint: OK"
exit "$fail"
