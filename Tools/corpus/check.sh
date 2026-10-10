#!/bin/zsh
# Typechecks the corpus against Apple SwiftUI (must succeed) — SwiftUI2 compiles it as a test.
cd "$(dirname $0)"
tmp=$(mktemp -d)
for f in Corpus*.swift; do cp $f $tmp/$f; done
xcrun swiftc -typecheck -target arm64-apple-macos26.0 $tmp/*.swift 2>&1 | grep -E "error" | head -40
rm -rf $tmp
