#!/usr/bin/env bash
# Link libxul (XUL) onto APFS and point dist/.app at it.
#
# Large Mach-O images linked directly on ExFAT can fail dyld loading ("rebase
# opcodes terminated early"). The object directory stays on the external volume;
# only this one runtime library (~210MB) lives on the boot volume.
#
# Safe to re-run. Does not delete the object directory or other build outputs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBJDIR=""
if [[ -f "$ROOT/mozconfig" ]]; then
  OBJDIR="$(sed -n 's/^mk_add_options MOZ_OBJDIR=//p' "$ROOT/mozconfig" | tail -1 | tr -d '"')"
fi
if [[ -z "$OBJDIR" || ! -d "$OBJDIR/toolkit/library/build" ]]; then
  echo "link-xul-apfs: MOZ_OBJDIR or toolkit/library/build not found" >&2
  exit 1
fi

RUNTIME="${PEPPERMINT_XUL_RUNTIME:-$HOME/Library/Application Support/Peppermint/runtime/XUL}"
BUILD="$OBJDIR/toolkit/library/build"
DIST_XUL="$OBJDIR/dist/bin/XUL"
APP_XUL="$OBJDIR/dist/Peppermint.app/Contents/MacOS/XUL"
CLANG="${MOZ_CLANG:-$HOME/.mozbuild/clang/bin/clang++}"

export TMPDIR="${TMPDIR:-$HOME/.mozbuild/tmp}"
export COPYFILE_DISABLE=1
mkdir -p "$TMPDIR" "$(dirname "$RUNTIME")"

if [[ ! -x "$CLANG" ]]; then
  echo "link-xul-apfs: Firefox toolchain clang not found at $CLANG" >&2
  exit 1
fi

cd "$BUILD"
"$CLANG" \
  -isysroot "$HOME/.mozbuild/MacOSX26.5.sdk" \
  -mmacosx-version-min=11.0 -stdlib=libc++ -std=gnu++20 \
  -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
  -fstrict-flex-arrays=1 -fno-rtti -pthread -fno-sized-deallocation \
  -fno-aligned-new -ffunction-sections -fdata-sections -fno-math-errno \
  -fno-exceptions -fdiagnostics-absolute-paths -fPIC -O3 \
  -fno-omit-frame-pointer -funwind-tables \
  -o "$RUNTIME" \
  -Wl,@"$BUILD/XUL.list" \
  -fuse-ld=lld -fstack-protector-strong -lresolv \
  -Wl,-rpath,@executable_path/../Frameworks/ChannelPrefs.framework -Wl,-dead_strip \
  ../../../third_party/angle/translator_gn/libtranslator_gn.a \
  ../../../third_party/angle/angle_common_gn/libangle_common_gn.a \
  ../../../third_party/angle/angle_common_shader_state_gn/libangle_common_shader_state_gn.a \
  ../../../third_party/angle/preprocessor_gn/libpreprocessor_gn.a \
  ../../../js/src/build/libjs_static.a \
  ../../../build/pure_virtual/libpure_virtual.a \
  ../../../aarch64-apple-darwin/release/libgkrust.a \
  ../../../dist/bin/libnss3.dylib \
  ../../../dist/bin/libgkcodecs.dylib \
  ../../../dist/bin/liblgpllibs.dylib \
  ../../../dist/bin/ChannelPrefs \
  ../../../dist/bin/libmozglue.dylib \
  -Wl,-exported_symbols_list,XUL.symbols \
  -dynamiclib -install_name @rpath/XUL \
  -compatibility_version 1 -current_version 1 \
  -framework AuthenticationServices -lbsm -framework IOSurface -framework Metal \
  -framework IOKit -framework AudioToolbox -framework CoreMedia -framework VideoToolbox \
  -Wl,-U,_VTRegisterSupplementalVideoDecoderIfAvailable \
  -framework Foundation -framework AppKit -framework AVFoundation \
  -framework CoreGraphics -framework CoreVideo -framework QuartzCore \
  -framework IOBluetooth -framework CoreFoundation -framework Accessibility \
  -framework Vision -framework LocalAuthentication -framework Security \
  -weak_framework UniformTypeIdentifiers -lm -framework MediaPlayer \
  -framework AddressBook -framework ApplicationServices -framework AudioUnit \
  -framework Carbon -framework CoreAudio -framework CoreLocation \
  -framework CoreMIDI -framework CoreServices -framework OpenGL \
  -framework ServiceManagement -framework SystemConfiguration \
  -weak_framework ScreenCaptureKit -lcups

rm -f "$DIST_XUL"
ln -sf "$RUNTIME" "$DIST_XUL"
if [[ -d "$(dirname "$APP_XUL")" ]]; then
  rm -f "$APP_XUL"
  ln -sf "$RUNTIME" "$APP_XUL"
fi

printf 'Linked XUL on APFS: %s\n' "$RUNTIME"
