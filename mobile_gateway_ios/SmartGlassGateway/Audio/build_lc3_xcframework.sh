#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SRC_DIR="$DIR/liblc3/src"
INC_DIR="$DIR/liblc3/include"
BUILD_DIR="$DIR/build_temp"

rm -rf "$BUILD_DIR" "$DIR/LC3.xcframework"
mkdir -p "$BUILD_DIR/iphoneos" "$BUILD_DIR/iphonesimulator-arm64" "$BUILD_DIR/iphonesimulator-x86_64" "$BUILD_DIR/iphonesimulator" "$BUILD_DIR/macos" "$BUILD_DIR/headers"

cp "$INC_DIR/lc3.h" "$INC_DIR/lc3_private.h" "$BUILD_DIR/headers/"
cat << 'MOD' > "$BUILD_DIR/headers/module.modulemap"
module LC3 [system] {
    header "lc3.h"
    export *
}
MOD

SOURCES=(
    "$SRC_DIR/attdet.c"
    "$SRC_DIR/bits.c"
    "$SRC_DIR/bwdet.c"
    "$SRC_DIR/energy.c"
    "$SRC_DIR/lc3.c"
    "$SRC_DIR/ltpf.c"
    "$SRC_DIR/mdct.c"
    "$SRC_DIR/plc.c"
    "$SRC_DIR/sns.c"
    "$SRC_DIR/spec.c"
    "$SRC_DIR/tables.c"
    "$SRC_DIR/tns.c"
)

CFLAGS="-O3 -std=c11 -ffast-math -I$INC_DIR -Wall"

# 1. Compile for iOS Device (arm64)
IPHONEOS_SDK=$(xcrun --show-sdk-path --sdk iphoneos)
for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/iphoneos/$(basename "$src" .c).o"
    xcrun clang -target arm64-apple-ios16.0 -isysroot "$IPHONEOS_SDK" $CFLAGS -c "$src" -o "$obj"
done
xcrun libtool -static -o "$BUILD_DIR/iphoneos/liblc3.a" "$BUILD_DIR"/iphoneos/*.o

# 2. Compile for iOS Simulator (arm64 + x86_64 fat archive)
SIM_SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/iphonesimulator-arm64/$(basename "$src" .c).o"
    xcrun clang -target arm64-apple-ios16.0-simulator -isysroot "$SIM_SDK" $CFLAGS -c "$src" -o "$obj"
done
xcrun libtool -static -o "$BUILD_DIR/iphonesimulator-arm64/liblc3.a" "$BUILD_DIR"/iphonesimulator-arm64/*.o

for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/iphonesimulator-x86_64/$(basename "$src" .c).o"
    xcrun clang -target x86_64-apple-ios16.0-simulator -isysroot "$SIM_SDK" $CFLAGS -c "$src" -o "$obj"
done
xcrun libtool -static -o "$BUILD_DIR/iphonesimulator-x86_64/liblc3.a" "$BUILD_DIR"/iphonesimulator-x86_64/*.o

lipo -create \
    "$BUILD_DIR/iphonesimulator-arm64/liblc3.a" \
    "$BUILD_DIR/iphonesimulator-x86_64/liblc3.a" \
    -output "$BUILD_DIR/iphonesimulator/liblc3.a"

# 3. Compile for macOS (arm64)
MACOS_SDK=$(xcrun --show-sdk-path --sdk macosx)
for src in "${SOURCES[@]}"; do
    obj="$BUILD_DIR/macos/$(basename "$src" .c).o"
    xcrun clang -target arm64-apple-macos12.0 -isysroot "$MACOS_SDK" $CFLAGS -c "$src" -o "$obj"
done
xcrun libtool -static -o "$BUILD_DIR/macos/liblc3.a" "$BUILD_DIR"/macos/*.o

# 4. Create Universal XCFramework
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/iphoneos/liblc3.a" -headers "$BUILD_DIR/headers" \
    -library "$BUILD_DIR/iphonesimulator/liblc3.a" -headers "$BUILD_DIR/headers" \
    -library "$BUILD_DIR/macos/liblc3.a" -headers "$BUILD_DIR/headers" \
    -output "$DIR/LC3.xcframework"

rm -rf "$BUILD_DIR"
echo "Successfully generated universal $DIR/LC3.xcframework"
