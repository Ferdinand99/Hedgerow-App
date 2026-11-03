#!/usr/bin/env bash
# Tests scripts/ThirdPartyNotices.swift with made-up packages: it must accept an allowed licence and
# write its text, and it must fail on a licence that is not allowed, a missing licence file, a
# licence template without a copyright notice, a stale file, and a package that Package.resolved
# does not cover. Needs swiftc. Run from anywhere.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

swiftc -O -o "$tmp/notices" "$root/scripts/ThirdPartyNotices.swift"

MIT_TEXT='MIT License

Copyright (c) 2024 Example Author

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.'

GPL_TEXT='GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Everyone is permitted to copy and distribute verbatim copies of this license document.'

fresh() { # a clean case folder
  rm -rf "$tmp/case"
  mkdir -p "$tmp/case/checkouts" "$tmp/case/Hedgerow"
  printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Core", targets: [])\n' > "$tmp/case/Package.swift"
  printf 'name: Hedgerow\npackages:\n  HedgerowCore:\n    path: HedgerowCore\ntargets:\n  Hedgerow: {}\n' > "$tmp/case/project.yml"
}

pin() { # identity
  printf '{ "pins": [ { "identity": "%s", "kind": "remoteSourceControl", "location": "https://example.com/%s.git", "state": { "revision": "0123456789abcdef", "version": "1.2.3" } } ], "version": 3 }\n' "$1" "$1" > "$tmp/case/Package.resolved"
}

notices() { # extra arguments
  "$tmp/notices" --resolved "$tmp/case/Package.resolved" --checkouts "$tmp/case/checkouts" \
    --manifest "$tmp/case/Package.swift" --project "$tmp/case/project.yml" --output "$tmp/case/Hedgerow/ThirdPartyNotices.txt" "$@"
}

expect_fail() { # description, arguments
  local what="$1"; shift
  if notices "$@" >/dev/null 2>"$tmp/err"; then
    echo "ERROR: $what was accepted." >&2
    exit 1
  fi
  echo "$what: stopped, as it must ($(head -n1 "$tmp/err" | cut -c1-90))."
}

# 1. No dependencies at all.
fresh
notices >/dev/null
grep -q 'no third-party Swift packages' "$tmp/case/Hedgerow/ThirdPartyNotices.txt"
notices --check >/dev/null
echo "No packages: file written and up to date."

# 2. An allowed licence, then a stale file.
fresh; pin goodpkg
mkdir -p "$tmp/case/checkouts/goodpkg"
printf '%s\n' "$MIT_TEXT" > "$tmp/case/checkouts/goodpkg/LICENSE"
notices >/dev/null
grep -q 'goodpkg 1.2.3 (https://example.com/goodpkg.git)' "$tmp/case/Hedgerow/ThirdPartyNotices.txt"
grep -q 'Copyright (c) 2024 Example Author' "$tmp/case/Hedgerow/ThirdPartyNotices.txt"
notices --check >/dev/null
echo "MIT package: accepted, text in the file."
echo "stale" >> "$tmp/case/Hedgerow/ThirdPartyNotices.txt"
expect_fail "A stale file" --check

# 3. A licence that is not allowed.
fresh; pin gplpkg
mkdir -p "$tmp/case/checkouts/gplpkg"
printf '%s\n' "$GPL_TEXT" > "$tmp/case/checkouts/gplpkg/LICENSE"
expect_fail "A GPL package"

# 4. No licence file.
fresh; pin nolicense
mkdir -p "$tmp/case/checkouts/nolicense"
echo "no licence here" > "$tmp/case/checkouts/nolicense/README.md"
expect_fail "A package without a licence file"

# 5. A licence template without a copyright notice.
fresh; pin template
mkdir -p "$tmp/case/checkouts/template"
printf '%s\n' "${MIT_TEXT/Copyright (c) 2024 Example Author/Copyright (c) <year> <copyright holders>}" > "$tmp/case/checkouts/template/LICENSE"
expect_fail "A licence template without a copyright notice"

# 6. A package in the manifest, but no Package.resolved.
fresh
printf '// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "Core", dependencies: [.package(url: "https://example.com/x.git", from: "1.0.0")], targets: [])\n' > "$tmp/case/Package.swift"
expect_fail "A package from a URL without Package.resolved"

# 7. A package from a URL in project.yml.
fresh
printf 'name: Hedgerow\npackages:\n  Other:\n    url: https://example.com/other.git\n    from: 1.0.0\ntargets:\n  Hedgerow: {}\n' > "$tmp/case/project.yml"
expect_fail "A package from a URL in project.yml"

echo "OK"
