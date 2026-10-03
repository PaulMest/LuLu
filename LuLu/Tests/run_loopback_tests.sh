#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/lulu-policy-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT
clang -fobjc-arc -fmodules -Wno-deprecated-declarations -DNS_BLOCK_ASSERTIONS \
    -framework Foundation -framework NetworkExtension \
    -I "$root/LuLu/Extension" -I "$root/LuLu/Shared" \
    "$root/LuLu/Tests/test_loopback_settings.m" -o "$build/settings"
"$build/settings"
clang -fobjc-arc -fmodules -Wno-deprecated-declarations -Wno-incomplete-implementation \
    -framework Foundation -framework NetworkExtension -framework Cocoa \
    -I "$root/LuLu/Extension" -I "$root/LuLu/Shared" \
    "$root/LuLu/Extension/LoopbackPolicy.m" "$root/LuLu/Extension/Preferences.m" \
    "$root/LuLu/Tests/test_loopback_policy.m" -o "$build/transitions"
"$build/transitions"

sh "$root/LuLu/Tests/run_loopback_regressions.sh"
python3 "$root/LuLu/Tests/test_profile_notifications.py"
