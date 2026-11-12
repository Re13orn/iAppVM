#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_out="$task_root/build/hwhook"
mkdir -p "$task_out"
task_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
task_flags=(-arch arm64 -isysroot "$task_sdk" -miphoneos-version-min=15.0 -dynamiclib -fblocks -O0 -Wall -Wextra -Wno-unused-parameter)
xcrun --sdk iphoneos clang "${task_flags[@]}" "$task_root/TestTools/HWHook/SDK/iOSVMHWHook.c" \
  -Wl,-install_name,@rpath/iOSVMHWHook.dylib -o "$task_out/iOSVMHWHook.dylib"
xcrun --sdk iphoneos clang "${task_flags[@]}" -framework Foundation \
  "$task_root/TestTools/HWHook/Smoke.m" "$task_out/iOSVMHWHook.dylib" -Wl,-rpath,@loader_path \
  -o "$task_out/HWHookSmoke.dylib"
cp "$task_root/TestTools/HWHook/SDK/iOSVMHWHook.h" "$task_out/"
printf 'Built SDK and self-contained test plugin in %s\n' "$task_out"
