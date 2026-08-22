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
# Strip comments, but not the `//` inside a URL: `s,//.*,,` also eats
# `https://github.com/...`, which silently defeated the check below — the
# first version of this gate passed a manifest that did declare a package.
manifest=$(sed -e 's,^[[:space:]]*//.*,,' -e 's,\([^:]\)//.*,\1,' Package.swift)
# Fetched packages are permitted only when pure Swift and supported on macOS,
# iOS and Linux alike, and each must be listed here — so adding one is a
# decision with a name on it rather than a line that slipped into the
# manifest. The list is empty today: every candidate examined so far replaced
# less code than it cost, and the first fetch also ends this project's
# offline CI.
allowed_packages=''
for pkg in $(printf '%s' "$manifest" | grep -oE '\.package\(url: "[^"]+"' | sed 's/.*\///;s/"//'); do
    case " $allowed_packages " in
        *" $pkg "*) ;;
        *) echo "FAIL: undeclared fetched dependency: $pkg" >&2; fail=1 ;;
    esac
done

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
