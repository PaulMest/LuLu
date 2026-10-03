#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/lulu-regressions.XXXXXX")
trap 'rm -rf "$build"' EXIT
clang -fmodules-cache-path="$build/modules" -fobjc-arc -fmodules -Wno-deprecated-declarations -Wno-incomplete-implementation -Wno-incompatible-pointer-types \
 -framework Foundation -framework NetworkExtension -framework Cocoa \
 -I "$root/LuLu/Extension" -I "$root/LuLu/Shared" \
 "$root/LuLu/Extension/LoopbackPolicy.m" "$root/LuLu/Extension/Preferences.m" "$root/LuLu/Extension/Profiles.m" \
 "$root/LuLu/Tests/test_loopback_regressions.m" -o "$build/regressions"
failed=0
for case in flow-profile-read timeout-recovery newer-policy save-recovery load-recovery delete-rollback add-cleanup add-selection-failure default-selection profile-list add-success reuse-incomplete; do
 "$build/regressions" "$case" || failed=1
done
exit "$failed"
