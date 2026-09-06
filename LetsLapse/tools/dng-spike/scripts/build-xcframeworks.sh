#!/bin/zsh
# build-xcframeworks.sh — libjxl (with highway, brotli, skcms) and LibRaw as
# static XCFrameworks for iOS (device, arm64), iOS Simulator (arm64) and
# macOS (arm64 + x86_64 — a Release build of the app is universal, and an
# arm64-only slice leaves every Jxl*/libraw* symbol undefined in the x86_64
# link).
#
#   scripts/build-xcframeworks.sh            # everything
#   ONLY=jxl scripts/build-xcframeworks.sh   # one library
#   SLICES="ios mac" …                       # a subset of slices
#   FORCE=1 …                                # rebuild slices whose output exists
#
# The two macOS slices (`mac` arm64, `macx86` x86_64) are lipo'd into one
# universal library before the xcframework is assembled.
#
# Sources are fetched from the projects' own release points (libjxl's GitHub
# tag, LibRaw's release tarball). Output lands in .xcframeworks/ next to the
# package: CJXL.xcframework and CLibRaw.xcframework plus a sizes.txt. Wire
# them in as `binaryTarget`s in Package.swift to build without Homebrew.
#
# Licences: libjxl BSD-3-Clause; highway Apache-2.0 / BSD-3; brotli MIT;
# skcms BSD-3; LibRaw LGPL-2.1 or CDDL-1.0 (dual) — see the report's
# licensing section before shipping any of them in the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.xcframeworks}"
JXL_VERSION="${JXL_VERSION:-v0.11.1}"
LIBRAW_VERSION="${LIBRAW_VERSION:-0.21.4}"
IOS_MIN="${IOS_MIN:-16.0}"
MACOS_MIN="${MACOS_MIN:-13.0}"
SLICES="${SLICES:-ios iossim mac macx86}"
ONLY="${ONLY:-jxl libraw}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$WORK"
cd "$WORK"

sdk_path() { xcrun --sdk "$1" --show-sdk-path; }
slice_sysroot() {
  case "$1" in
    ios) echo iphoneos ;;
    iossim) echo iphonesimulator ;;
    mac|macx86) echo macosx ;;
  esac
}
slice_host() {
  case "$1" in
    macx86) echo x86_64-apple-darwin ;;
    *) echo aarch64-apple-darwin ;;
  esac
}
# One library per xcframework platform: prints the library for each slice,
# folding `mac` + `macx86` into a universal `macuni` build with lipo.
xcf_libs() {
  local prefix="$1" lib="$2" slice
  for slice in ${=SLICES}; do
    case "$slice" in
      macx86) ;;
      mac)
        if [[ " $SLICES " == *" macx86 "* && -f "$prefix-macx86/$lib" ]]; then
          mkdir -p "$prefix-macuni"
          lipo -create "$prefix-mac/$lib" "$prefix-macx86/$lib" -output "$prefix-macuni/$lib"
          echo "$prefix-macuni/$lib"
        else
          echo "$prefix-mac/$lib"
        fi ;;
      *) echo "$prefix-$slice/$lib" ;;
    esac
  done
}
slice_cflags() {
  case "$1" in
    ios) echo "-arch arm64 -isysroot $(sdk_path iphoneos) -miphoneos-version-min=$IOS_MIN" ;;
    iossim) echo "-arch arm64 -isysroot $(sdk_path iphonesimulator) -mios-simulator-version-min=$IOS_MIN" ;;
    mac) echo "-arch arm64 -isysroot $(sdk_path macosx) -mmacosx-version-min=$MACOS_MIN" ;;
    macx86) echo "-arch x86_64 -isysroot $(sdk_path macosx) -mmacosx-version-min=$MACOS_MIN" ;;
  esac
}
slice_cmake_flags() {
  case "$1" in
    ios) echo "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN" ;;
    iossim) echo "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN" ;;
    mac) echo "-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN" ;;
    macx86) echo "-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN" ;;
  esac
}

build_jxl() {
  if [[ ! -d libjxl ]]; then
    git clone --depth 1 --branch "$JXL_VERSION" --recursive https://github.com/libjxl/libjxl.git
  fi
  for slice in ${=SLICES}; do
    local build="build-jxl-$slice"
    if [[ -f "out-jxl-$slice/libjxl_all.a" && -z "${FORCE:-}" ]]; then
      echo "== libjxl $JXL_VERSION · $slice (reusing out-jxl-$slice; FORCE=1 rebuilds)"
      continue
    fi
    echo "== libjxl $JXL_VERSION · $slice"
    # Cross-compiling for iOS: try_compile cannot link an executable, so the
    # pthread probe (and any other) must build a static library instead, and
    # Threads is told the answer outright.
    cmake -S libjxl -B "$build" -G "Unix Makefiles" \
      ${=$(slice_cmake_flags $slice)} \
      -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_MACOSX_BUNDLE=OFF \
      -DBROTLI_BUNDLED_MODE=ON -DBROTLI_DISABLE_TESTS=ON \
      -DCMAKE_THREAD_LIBS_INIT=-lpthread -DCMAKE_HAVE_THREADS_LIBRARY=1 -DCMAKE_USE_PTHREADS_INIT=1 -DTHREADS_PREFER_PTHREAD_FLAG=ON \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
      -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
      -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
      -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_ENABLE_DOXYGEN=OFF \
      -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
      -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF -DJPEGXL_ENABLE_TCMALLOC=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF \
      -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF -DJPEGXL_FORCE_SYSTEM_LCMS2=OFF \
      -DJPEGXL_STATIC=ON
    cmake --build "$build" --target jxl jxl_threads jxl_cms -j "$JOBS"
    mkdir -p "out-jxl-$slice"
    local libs=()
    for name in libjxl.a libjxl_threads.a libjxl_cms.a libhwy.a libbrotlicommon.a libbrotlienc.a libbrotlidec.a libskcms.a libjxl_dec.a libjxl_enc.a libjxl_base.a; do
      local found
      found="$(find "$build" -name "$name" -print -quit)"
      [[ -n "$found" ]] && libs+=("$found")
    done
    libtool -static -o "out-jxl-$slice/libjxl_all.a" "${libs[@]}"
    ls -la "out-jxl-$slice/libjxl_all.a"
  done
  mkdir -p include-jxl
  rm -rf include-jxl/jxl
  cp -R libjxl/lib/include/jxl include-jxl/
  cp -R build-jxl-${${=SLICES}[1]}/lib/include/jxl/* include-jxl/jxl/ 2>/dev/null || true
  # A module map so Swift can `import CJXL` straight from the xcframework.
  cat > include-jxl/module.modulemap <<'MAP'
module CJXL {
    header "jxl/encode.h"
    header "jxl/decode.h"
    header "jxl/thread_parallel_runner.h"
    header "jxl/resizable_parallel_runner.h"
    header "jxl/color_encoding.h"
    header "jxl/codestream_header.h"
    header "jxl/types.h"
    header "jxl/version.h"
    export *
}
MAP
  rm -rf CJXL.xcframework
  local args=() lib
  for lib in $(xcf_libs out-jxl libjxl_all.a); do args+=(-library "$lib" -headers include-jxl); done
  xcodebuild -create-xcframework "${args[@]}" -output CJXL.xcframework
}

build_libraw() {
  local tar="LibRaw-$LIBRAW_VERSION.tar.gz"
  if [[ ! -d "LibRaw-$LIBRAW_VERSION" ]]; then
    curl -fL -o "$tar" "https://www.libraw.org/data/$tar"
    tar xzf "$tar"
  fi
  for slice in ${=SLICES}; do
    if [[ -f "out-libraw-$slice/libraw_r.a" && -z "${FORCE:-}" ]]; then
      echo "== LibRaw $LIBRAW_VERSION · $slice (reusing out-libraw-$slice; FORCE=1 rebuilds)"
      continue
    fi
    echo "== LibRaw $LIBRAW_VERSION · $slice"
    local src="LibRaw-$LIBRAW_VERSION" build="build-libraw-$slice"
    rm -rf "$build" && cp -R "$src" "$build"
    local flags; flags="$(slice_cflags $slice)"
    (
      cd "$build"
      CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" \
      CFLAGS="$flags -O2" CXXFLAGS="$flags -O2 -std=c++11" LDFLAGS="$flags" \
      ./configure --host="$(slice_host $slice)" --disable-shared --enable-static \
        --disable-openmp --disable-jpeg --disable-zlib --disable-lcms --disable-examples --disable-jasper >/dev/null
      make -j "$JOBS" >/dev/null
    )
    mkdir -p "out-libraw-$slice"
    cp "$build/lib/.libs/libraw_r.a" "out-libraw-$slice/libraw_r.a"
    ls -la "out-libraw-$slice/libraw_r.a"
  done
  mkdir -p include-libraw/libraw
  cp "LibRaw-$LIBRAW_VERSION"/libraw/*.h include-libraw/libraw/
  # Module map plus a shim: Swift does not import C arrays past 4096
  # elements, and `cblack` is 4102.
  cat > include-libraw/libraw_shim.h <<'SHIM'
#include "libraw/libraw.h"

static inline unsigned letslapse_libraw_cblack(const libraw_data_t *data, int index) {
    return data->color.cblack[index];
}
SHIM
  cat > include-libraw/module.modulemap <<'MAP'
module CLibRaw {
    header "libraw/libraw.h"
    header "libraw_shim.h"
    export *
}
MAP
  rm -rf CLibRaw.xcframework
  local args=() lib
  for lib in $(xcf_libs out-libraw libraw_r.a); do args+=(-library "$lib" -headers include-libraw); done
  xcodebuild -create-xcframework "${args[@]}" -output CLibRaw.xcframework
}

for lib in ${=ONLY}; do
  case "$lib" in
    jxl) build_jxl ;;
    libraw) build_libraw ;;
  esac
done

# The Kit ships ONE xcframework holding both libraries with one module map
# declaring the two modules: Xcode flattens every static xcframework's headers
# into a single include folder, so two frameworks cannot both carry a root
# module.modulemap (the build fails with "Multiple commands produce
# …/include/module.modulemap").
merge_codecs() {
  [[ -d CJXL.xcframework && -d CLibRaw.xcframework ]] || return 0
  rm -rf merge && mkdir -p merge/headers
  cp -R include-jxl/jxl merge/headers/
  cp -R include-libraw/libraw merge/headers/
  cp include-libraw/libraw_shim.h merge/headers/
  cat > merge/headers/module.modulemap <<'MAP'
module CJXL {
    header "jxl/encode.h"
    header "jxl/decode.h"
    header "jxl/thread_parallel_runner.h"
    header "jxl/resizable_parallel_runner.h"
    header "jxl/color_encoding.h"
    header "jxl/codestream_header.h"
    header "jxl/types.h"
    header "jxl/version.h"
    export *
}

module CLibRaw {
    header "libraw/libraw.h"
    header "libraw_shim.h"
    export *
}
MAP
  # libtool -static keeps fat inputs fat, so the universal macOS pair stays
  # universal in the merged library.
  local jxl_libs=($(xcf_libs out-jxl libjxl_all.a))
  local raw_libs=($(xcf_libs out-libraw libraw_r.a))
  local args=() i key
  for (( i = 1; i <= ${#jxl_libs[@]}; i++ )); do
    key="${jxl_libs[$i]:h:t}"; key="${key#out-jxl-}"
    mkdir -p "merge/$key"
    libtool -static -o "merge/$key/libLetsLapseCodecs.a" "${jxl_libs[$i]}" "${raw_libs[$i]}"
    lipo -info "merge/$key/libLetsLapseCodecs.a"
    args+=(-library "merge/$key/libLetsLapseCodecs.a" -headers merge/headers)
  done
  rm -rf CLetsLapseCodecs.xcframework
  xcodebuild -create-xcframework "${args[@]}" -output CLetsLapseCodecs.xcframework
  echo "Kit copy: rm -rf ../../Kit/Binaries/CLetsLapseCodecs.xcframework && cp -R CLetsLapseCodecs.xcframework ../../Kit/Binaries/"
}
merge_codecs

{
  echo "built $(date)"
  for f in CJXL.xcframework CLibRaw.xcframework CLetsLapseCodecs.xcframework; do
    [[ -d $f ]] && du -sh "$f" && find "$f" -name "*.a" -exec ls -la {} \;
  done
} | tee sizes.txt
