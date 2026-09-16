#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the LWJGL 3.4.1 native libraries (core + OpenGL ES) for one Android ABI.
#
# Produces, inside <outdir>:
#     linux/<lwjgl_arch>/org/lwjgl/liblwjgl.so
#     linux/<lwjgl_arch>/org/lwjgl/opengles/liblwjgl_opengles.so
#     BUILD-INFO.txt
#
# The layout mirrors LWJGL's own natives-jar layout, so the result is a drop-in
# replacement for the `linux/<arch>` native resource tree of a Java project.
#
# The recipe reproduces LWJGL's upstream Ant native build
# (config/linux/build.xml in the LWJGL repository) with these intentional
# changes, all documented in README.md:
#   * libffi.a is built for Android instead of using LWJGL's glibc prebuilt
#   * miniz is compiled into liblwjgl.so as well
#   * io_uring / UIO are excluded (kernel-only interfaces, unusable on Android)
#   * no linker version script, no strip: DWARF and all symbols are kept
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --abi <abi> [options]

Required:
  --abi <abi>          one of: ${ALL_ABIS[*]}

Options:
  --workdir <dir>      scratch directory (default: ./build)
  --outdir <dir>       staging output directory (default: ./dist)
  --jobs <n>           parallel compile jobs (default: number of CPUs)
  --werror             treat compiler warnings as errors
  -h, --help           show this help
EOF
}

ABI=""
WORKDIR="build"
OUTDIR="dist"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)"
WERROR="${WERROR:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)     ABI="$2";     shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --outdir)  OUTDIR="$2";  shift 2 ;;
        --jobs)    JOBS="$2";    shift 2 ;;
        --werror)  WERROR=1;     shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$ABI" ]] || { usage >&2; die "--abi is required"; }
abi_supported "$ABI" || die "unsupported ABI '$ABI' (supported: ${ALL_ABIS[*]})"

require_cmd git
require_cmd make

# sha256sum (coreutils) on Linux, shasum on macOS.
hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        die "neither sha256sum nor shasum is available"
    fi
}

# ---------------------------------------------------------------------------
# Resolve the Android NDK
# ---------------------------------------------------------------------------

ndk_host_tag() {
    case "$(uname -s)" in
        Linux)  echo "linux-x86_64" ;;
        Darwin) echo "darwin-x86_64" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows-x86_64" ;;
        *) die "unsupported build host: $(uname -s)" ;;
    esac
}

# An Android SDK install ships source.properties with e.g.
#     Pkg.Revision = 29.0.14206865
# GitHub's runner images preinstall several NDK revisions and export
# ANDROID_NDK_HOME pointing at the default one, which is usually NOT the revision
# we pin. Never silently build with the wrong toolchain.
ndk_revision_matches() {
    local root="$1"
    # Reject anything that is not a usable NDK for some host ...
    [[ -n "$root" && -d "$root/toolchains/llvm/prebuilt" ]] || return 1
    # ... and fail closed when the metadata is missing: without source.properties
    # the revision cannot be proven, so the candidate is not trusted. Both the
    # Android SDK install and the standalone archive ship this file.
    [[ -f "$root/source.properties" ]] || return 1
    grep -qxF "Pkg.Revision = ${NDK_VERSION}" "$root/source.properties"
}

resolve_ndk() {
    local candidate

    # An explicitly configured NDK is honoured, but only if it really is the
    # pinned revision (SKIP_NDK_VERSION_CHECK=1 forces it through).
    for candidate in "${NDK_HOME:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
        [[ -n "$candidate" && -d "$candidate" ]] || continue
        if ndk_revision_matches "$candidate"; then
            (cd "$candidate" && pwd)
            return 0
        fi
        if [[ "${SKIP_NDK_VERSION_CHECK:-0}" == "1" ]]; then
            warn "using $candidate despite the revision mismatch (SKIP_NDK_VERSION_CHECK=1)"
            (cd "$candidate" && pwd)
            return 0
        fi
        warn "ignoring $candidate: it is not NDK $NDK_VERSION"
    done

    # SDK style installs: <sdk>/ndk/<revision>
    for candidate in \
        "${ANDROID_SDK_ROOT:-}/ndk/${NDK_VERSION}" \
        "${ANDROID_HOME:-}/ndk/${NDK_VERSION}"; do
        [[ -n "$candidate" && -d "$candidate" ]] || continue
        if ndk_revision_matches "$candidate"; then
            (cd "$candidate" && pwd)
            return 0
        fi
        warn "ignoring $candidate: Pkg.Revision does not match $NDK_VERSION"
    done

    return 1
}

if ! NDK_ROOT="$(resolve_ndk)"; then
    die "Android NDK ${NDK_VERSION} not found.
       Looked at \$NDK_HOME, \$ANDROID_NDK_HOME, \$ANDROID_NDK_ROOT and
       \$ANDROID_SDK_ROOT/ndk/${NDK_VERSION}. On GitHub runners the SDK ships
       this revision already; locally set NDK_HOME to it, or install it with
       'sdkmanager --install \"ndk;${NDK_VERSION}\"'."
fi

NDK_BIN="$NDK_ROOT/toolchains/llvm/prebuilt/$(ndk_host_tag)/bin"
[[ -d "$NDK_BIN" ]] || die "NDK toolchain directory not found: $NDK_BIN"

# The Windows NDK ships .cmd wrappers instead of extension-less shims.
tool() {
    local base="$1"
    if [[ -x "$NDK_BIN/$base" ]]; then
        echo "$NDK_BIN/$base"
    elif [[ -f "$NDK_BIN/$base.cmd" ]]; then
        echo "$NDK_BIN/$base.cmd"
    elif [[ -x "$NDK_BIN/$base.exe" ]]; then
        echo "$NDK_BIN/$base.exe"
    else
        die "NDK tool not found: $NDK_BIN/$base"
    fi
}

NDK_TRIPLE="$(abi_ndk_triple "$ABI")"
LWJGL_ARCH="$(abi_lwjgl_arch "$ABI")"
FFI_INC_DIR="$(abi_ffi_include_dir "$ABI")"
EXTRA_DEFINES="$(abi_extra_defines "$ABI")"

CC="$(tool "${NDK_TRIPLE}${ANDROID_API}-clang")"
AR="$(tool llvm-ar)"
RANLIB="$(tool llvm-ranlib)"

mkdir -p "$WORKDIR" "$OUTDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
OUTDIR="$(cd "$OUTDIR" && pwd)"

SRC_DIR="$WORKDIR/src"
BUILD_DIR="$WORKDIR/obj/$ABI"
OBJ_DIR="$BUILD_DIR/o"
STAGE_DIR="$OUTDIR/linux/$LWJGL_ARCH"
mkdir -p "$SRC_DIR" "$OBJ_DIR" "$STAGE_DIR/org/lwjgl/opengles"

info "ABI         : $ABI ($(abi_description "$ABI"))"
info "resource dir: linux/$LWJGL_ARCH/org/lwjgl"
info "NDK         : $NDK_ROOT"
info "clang       : $CC"
info "libffi      : $LIBFFI_VERSION ($LIBFFI_COMMIT)"

# ---------------------------------------------------------------------------
# 1. Fetch and verify upstream sources
# ---------------------------------------------------------------------------

fetch_lwjgl() {
    local dest="$SRC_DIR/lwjgl3"
    if [[ ! -d "$dest/.git" ]]; then
        info "cloning LWJGL $LWJGL_VERSION (sparse checkout)"
        git clone --depth 1 --branch "$LWJGL_VERSION" --filter=blob:none --sparse \
            "$LWJGL_REPO" "$dest" >&2
        git -C "$dest" sparse-checkout set \
            modules/lwjgl/core/src modules/lwjgl/opengles/src >&2
    fi

    local actual
    actual="$(git -C "$dest" rev-parse HEAD)"
    [[ "$actual" == "$LWJGL_COMMIT" ]] || die \
        "LWJGL checkout is at $actual, expected tag $LWJGL_VERSION == $LWJGL_COMMIT"

    local rel expected actual_hash
    while read -r rel; do
        [[ -n "$rel" ]] || continue
        expected="$(pin_sha256 "$rel")"
        actual_hash="$(hash_file "$dest/$rel" | tr 'a-f' 'A-F')"
        [[ "$actual_hash" == "$expected" ]] || die \
            "sha256 mismatch for $rel (expected $expected, got $actual_hash)"
    done < <(pin_paths)

    info "LWJGL sources verified at $LWJGL_COMMIT"
    echo "$dest"
}

fetch_libffi() {
    local dest="$SRC_DIR/libffi"
    if [[ ! -d "$dest/.git" ]]; then
        info "cloning libffi v$LIBFFI_VERSION"
        git clone --depth 1 --branch "v$LIBFFI_VERSION" "$LIBFFI_REPO" "$dest" >&2
    fi
    local actual
    actual="$(git -C "$dest" rev-parse HEAD)"
    [[ "$actual" == "$LIBFFI_COMMIT" ]] || die \
        "libffi checkout is at $actual, expected v$LIBFFI_VERSION == $LIBFFI_COMMIT"
    info "libffi sources verified at $LIBFFI_COMMIT"
    echo "$dest"
}

LWJGL_SRC="$(fetch_lwjgl)"
LIBFFI_SRC="$(fetch_libffi)"

# ---------------------------------------------------------------------------
# 2. Build a static libffi for this ABI
#
# LWJGL compiles its generated libffi bindings against its own vendored ffi.h,
# so only the static library has to be produced. Debug info is suppressed
# (-g0) because libffi is an opaque dependency here.
# ---------------------------------------------------------------------------

LIBFFI_PREFIX="$BUILD_DIR/libffi-out"
LIBFFI_BUILD="$BUILD_DIR/libffi-build"

build_libffi() {
    if [[ -f "$LIBFFI_PREFIX/lib/libffi.a" ]]; then
        info "libffi.a already built for $ABI"
        return 0
    fi

    if [[ ! -x "$LIBFFI_SRC/configure" ]]; then
        require_cmd autoreconf
        info "generating libffi configure script"
        ( cd "$LIBFFI_SRC" && ./autogen.sh ) >"$BUILD_DIR/libffi-autogen.log" 2>&1 ||
            { tail -n 40 "$BUILD_DIR/libffi-autogen.log" >&2; die "libffi autogen.sh failed"; }
    fi

    mkdir -p "$LIBFFI_BUILD" "$LIBFFI_PREFIX"
    info "configuring libffi for $(abi_libffi_host "$ABI")"
    (
        cd "$LIBFFI_BUILD"
        "$LIBFFI_SRC/configure" \
            --host="$(abi_libffi_host "$ABI")" \
            --prefix="$LIBFFI_PREFIX" \
            --disable-shared \
            --enable-static \
            --disable-docs \
            CC="$CC" AR="$AR" RANLIB="$RANLIB" \
            CFLAGS="-O2 -fPIC -g0" \
            >"$BUILD_DIR/libffi-configure.log" 2>&1 ||
            { tail -n 40 "$BUILD_DIR/libffi-configure.log" >&2; die "libffi configure failed"; }

        make -j"$JOBS" >"$BUILD_DIR/libffi-make.log" 2>&1 ||
            { tail -n 40 "$BUILD_DIR/libffi-make.log" >&2; die "libffi build failed"; }

        make install >"$BUILD_DIR/libffi-install.log" 2>&1 ||
            { tail -n 40 "$BUILD_DIR/libffi-install.log" >&2; die "libffi install failed"; }
    )
}

build_libffi
LIBFFI_A="$(find "$LIBFFI_PREFIX" -name 'libffi.a' -print -quit)"
[[ -n "$LIBFFI_A" ]] || die "libffi.a was not produced under $LIBFFI_PREFIX"
info "libffi.a    : $LIBFFI_A"

# Fail early, with a precise message, if the static library does not provide
# everything the LWJGL objects need (wrong libffi version => 3.6+ ABI break).
verify_libffi_symbols() {
    local nm symbols_file missing=() sym
    nm="$(tool llvm-nm)"
    symbols_file="$BUILD_DIR/libffi-defined-symbols.txt"
    "$nm" --defined-only --format=posix "$LIBFFI_A" 2>/dev/null |
        awk '{print $1}' | sort -u >"$symbols_file"

    while read -r sym; do
        [[ -n "$sym" ]] || continue
        grep -qx -- "$sym" "$symbols_file" || missing+=("$sym")
    done < <(required_ffi_symbols)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        die "libffi $LIBFFI_VERSION does not provide ${#missing[@]} required symbol(s): ${missing[*]}
       Check that FFI_VERSION_STRING in modules/lwjgl/core/src/main/c/libffi/ffi.h matches LIBFFI_VERSION."
    fi
    info "libffi provides all $(required_ffi_symbols | grep -c .) required symbols"
}

verify_libffi_symbols

# ---------------------------------------------------------------------------
# 3. Compile
# ---------------------------------------------------------------------------

CORE_SRC_ROOT="$LWJGL_SRC/modules/lwjgl/core/src"
GLES_SRC_ROOT="$LWJGL_SRC/modules/lwjgl/opengles/src"

collect_core_sources() {
    find "$CORE_SRC_ROOT/main/c" -maxdepth 1 -name '*.c' -print
    # miniz is compiled into liblwjgl.so (the upstream Ant build leaves it out).
    echo "$CORE_SRC_ROOT/main/c/dependencies/miniz/miniz.c"
    find "$CORE_SRC_ROOT/generated/c" -maxdepth 1 -name '*.c' -print
    # io_uring and UIO are Linux-kernel-only interfaces, unavailable to Android
    # applications, so these three translation units are excluded.
    find "$CORE_SRC_ROOT/generated/c/linux" -maxdepth 1 -name '*.c' -print |
        grep -v -e '_UIO\.c$' -e 'liburing_LibIOURing\.c$' -e 'liburing_LibURing\.c$' || true
}

collect_gles_sources() {
    find "$GLES_SRC_ROOT/generated/c" -maxdepth 1 -name '*.c' -print
}

mapfile -t CORE_SRCS < <(collect_core_sources)
mapfile -t GLES_SRCS < <(collect_gles_sources)

# Guards against silent upstream drift.
[[ "${#CORE_SRCS[@]}" -eq 24 ]] || die \
    "expected 24 core translation units for LWJGL $LWJGL_VERSION, found ${#CORE_SRCS[@]}"
[[ "${#GLES_SRCS[@]}" -eq 135 ]] || die \
    "expected 135 OpenGL ES translation units for LWJGL $LWJGL_VERSION, found ${#GLES_SRCS[@]}"

obj_path() {
    local rel="${1#"$LWJGL_SRC/"}"
    rel="${rel%.c}"
    echo "$OBJ_DIR/${rel//\//_}.o"
}

compile_one() {
    "$CC" "${CUR_CFLAGS[@]}" -o "$(obj_path "$1")" "$1"
}

compile_all() {
    local -a pids=()
    local src pid
    for src in "$@"; do
        compile_one "$src" &
        pids+=("$!")
        if [[ "${#pids[@]}" -ge "$JOBS" ]]; then
            wait "${pids[0]}" || die "compilation failed"
            pids=("${pids[@]:1}")
        fi
    done
    for pid in "${pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" || die "compilation failed"
        fi
    done
}

# --- flags mirroring config/linux/build.xml --------------------------------
BASE_CFLAGS=(
    -c -std=gnu11
    -O3 -fPIC -pthread -DNDEBUG
    -DLWJGL_LINUX "-DLWJGL_$LWJGL_ARCH"
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -D_GNU_SOURCE
    -D_FILE_OFFSET_BITS=64
    -Wall -Wextra
    # Debug information is deliberately retained (the binaries are not
    # stripped) so native crashes can be symbolized.
    -g
)

if [[ "$WERROR" == "1" ]]; then
    BASE_CFLAGS+=(-Werror -Wfatal-errors)
fi

if [[ -n "$EXTRA_DEFINES" ]]; then
    # shellcheck disable=SC2206
    BASE_CFLAGS+=($EXTRA_DEFINES)
fi

# `jni.h` is taken from the NDK sysroot, so no JDK include directory is needed.
CORE_CFLAGS=(
    "${BASE_CFLAGS[@]}"
    -I"$CORE_SRC_ROOT/main/c"
    -I"$CORE_SRC_ROOT/main/c/linux"
    -I"$CORE_SRC_ROOT/main/c/libffi"
    -I"$CORE_SRC_ROOT/main/c/libffi/$FFI_INC_DIR"
)

GLES_CFLAGS=(
    "${BASE_CFLAGS[@]}"
    -I"$GLES_SRC_ROOT/main/c"
    -I"$CORE_SRC_ROOT/main/c"
    -I"$CORE_SRC_ROOT/main/c/linux"
)

CUR_CFLAGS=("${CORE_CFLAGS[@]}")
info "compiling liblwjgl.so (${#CORE_SRCS[@]} translation units, -j$JOBS)"
compile_all "${CORE_SRCS[@]}"

CORE_OBJS=()
for src in "${CORE_SRCS[@]}"; do CORE_OBJS+=("$(obj_path "$src")"); done

CUR_CFLAGS=("${GLES_CFLAGS[@]}")
info "compiling liblwjgl_opengles.so (${#GLES_SRCS[@]} translation units)"
compile_all "${GLES_SRCS[@]}"

GLES_OBJS=()
for src in "${GLES_SRCS[@]}"; do GLES_OBJS+=("$(obj_path "$src")"); done

# ---------------------------------------------------------------------------
# 4. Link
#
# No linker version script is applied and the output is not stripped, so all
# symbols stay exported and the DWARF sections survive.
# ---------------------------------------------------------------------------

CORE_SO="$STAGE_DIR/org/lwjgl/liblwjgl.so"
GLES_SO="$STAGE_DIR/org/lwjgl/opengles/liblwjgl_opengles.so"

LINK_COMMON=(
    -shared
    -Wl,--build-id=sha1
    -Wl,-z,noexecstack
    -Wl,--no-undefined
    -pthread
    -lm -ldl
)

# Object lists are passed through response files: the OpenGL ES link pulls in
# 135 objects, which overflows the Windows command-line limit when the script is
# run locally with the NDK's .cmd wrappers. Entries are quoted and use forward
# slashes because clang's response-file tokenizer treats a bare backslash as an
# escape character, which would otherwise mangle Windows paths.
write_response_file() {
    local out="$1"; shift
    : >"$out"
    local item
    for item in "$@"; do
        printf '"%s"\n' "${item//\\//}" >>"$out"
    done
}

CORE_RSP="$BUILD_DIR/link-core.rsp"
GLES_RSP="$BUILD_DIR/link-gles.rsp"
write_response_file "$CORE_RSP" "${CORE_OBJS[@]}" "$LIBFFI_A"
write_response_file "$GLES_RSP" "${GLES_OBJS[@]}"

info "linking liblwjgl.so"
"$CC" "${LINK_COMMON[@]}" \
    -Wl,-soname,liblwjgl.so \
    -o "$CORE_SO" \
    "@$CORE_RSP"

info "linking liblwjgl_opengles.so"
"$CC" "${LINK_COMMON[@]}" \
    -Wl,-soname,liblwjgl_opengles.so \
    -L"$STAGE_DIR/org/lwjgl" -llwjgl \
    -o "$GLES_SO" \
    "@$GLES_RSP"

# ---------------------------------------------------------------------------
# 5. Build metadata
# ---------------------------------------------------------------------------

write_build_info() {
    local out="$1"
    local core_sha gles_sha compiler
    core_sha="$(hash_file "$CORE_SO")"
    gles_sha="$(hash_file "$GLES_SO")"
    compiler="$("$CC" --version 2>/dev/null || echo unknown)"
    compiler="${compiler%%$'\n'*}"

    cat >"$out" <<EOF
android-lwjgl3 build information
================================

Android ABI          : $ABI
Android API (minSdk) : $ANDROID_API
Description          : $(abi_description "$ABI")
NDK                  : $NDK_VERSION
NDK location         : $NDK_ROOT
C compiler           : $compiler

LWJGL version        : $LWJGL_VERSION
LWJGL source         : $LWJGL_REPO @ $LWJGL_COMMIT
LWJGL modules        : lwjgl (core), lwjgl-opengles
Resource path        : linux/$LWJGL_ARCH/org/lwjgl/

libffi version       : $LIBFFI_VERSION
libffi source        : $LIBFFI_REPO @ $LIBFFI_COMMIT

Compile flags        : ${CORE_CFLAGS[*]}
Link flags           : ${LINK_COMMON[*]} -Wl,-soname,...
Stripped             : no (DWARF debug info retained)
Linker version script: none (all symbols exported)

Produced files
--------------
linux/$LWJGL_ARCH/org/lwjgl/liblwjgl.so
    sha256 $core_sha
linux/$LWJGL_ARCH/org/lwjgl/opengles/liblwjgl_opengles.so
    sha256 $gles_sha

Note: the ANGLE libraries (libEGL_angle.so, libGLESv2_angle.so,
libGLESv1_CM_angle.so) are NOT part of this archive. They are Android platform
prebuilts and have to be supplied separately.
EOF
}

write_build_info "$OUTDIR/BUILD-INFO.txt"

info "done: $CORE_SO"
info "done: $GLES_SO"
