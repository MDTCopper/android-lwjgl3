#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared constants and per-ABI helpers for the android-lwjgl3 build.
#
# This file is meant to be *sourced*, never executed directly.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. Pinned upstream revisions
#
#    Every revision is pinned to an immutable commit hash; scripts/build.sh
#    re-verifies the hash after cloning and fails the build on any mismatch.
# ---------------------------------------------------------------------------

LWJGL_VERSION="${LWJGL_VERSION:-3.4.1}"
LWJGL_COMMIT="b800ccffab14396fc529ddb6c931b7c5c5226763"
LWJGL_REPO="https://github.com/LWJGL/lwjgl3.git"

# libffi version is NOT arbitrary: LWJGL 3.4.1 vendors its own ffi.h, which
# hard-codes
#     #define FFI_VERSION_STRING "3.5.0"
#     #define FFI_VERSION_NUMBER 30500
#     #define FFI_TYPE_LAST       FFI_TYPE_COMPLEX
# libffi 3.6.0 added FFI_TYPE_UINT128/SINT128 (changing FFI_TYPE_LAST), so the
# static library must stay on the 3.5.x ABI line.
#
# The *release tarball* is used instead of a git checkout: libffi 3.5.0's
# configure.ac requires autoconf >= 2.72, while the CI images ship 2.71 (both
# Ubuntu 22.04 and 24.04), so autoreconf cannot regenerate ./configure there.
# The tarball carries a maintainer-generated configure, and every source file in
# it is byte-identical to tag v3.5.0, so the SHA-256 below pins exactly the same
# content as the commit does.
LIBFFI_VERSION="3.5.0"
LIBFFI_COMMIT="d2c78d2ebbd9e65401095c6a2f281fe5132f028b"
LIBFFI_REPO="https://github.com/libffi/libffi.git"
LIBFFI_TARBALL_URL="https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
LIBFFI_TARBALL_SHA256="8C72678628A5DD8782F08AD421D5A441E42C1C5C1B33E0BC211CBFCF1F3B3978"

# ---------------------------------------------------------------------------
# 2. Target configuration
# ---------------------------------------------------------------------------

# Android 11 == API 30
ANDROID_API="${ANDROID_API:-30}"

# Released NDK revision, as reported by the .note.android.ident note of the
# produced binaries ("r29" + "14206865").
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"

# ---------------------------------------------------------------------------
# 3. SHA-256 pins for the LWJGL files the recipe depends on most.
#    Paths are relative to the LWJGL checkout root.
# ---------------------------------------------------------------------------

pin_paths() {
    cat <<'EOF'
modules/lwjgl/core/src/main/c/common_tools.c
modules/lwjgl/core/src/main/c/libffi/ffi.h
modules/lwjgl/core/src/main/c/dependencies/miniz/miniz.c
modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_UNISTD.c
modules/lwjgl/opengles/src/generated/c/org_lwjgl_opengles_GLES20.c
EOF
}

pin_sha256() {
    case "$1" in
        modules/lwjgl/core/src/main/c/common_tools.c)
            echo "90665167605D92AD71A8CDE7AAD180AA38855BB5536F97E38FCC1D3CE2B2CBD8" ;;
        modules/lwjgl/core/src/main/c/libffi/ffi.h)
            echo "635E0F0C5898689F586A7C325117CCB6EAEAAB3F791F0761F6E8D045743A2AAC" ;;
        modules/lwjgl/core/src/main/c/dependencies/miniz/miniz.c)
            echo "8756860E8AB4D8C6942E12496B8081CFD291442CDBC6D13DBA4B993905128872" ;;
        modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_UNISTD.c)
            echo "578295A8348F838EC7B6CEC6304FAFF6AC675FEED55107825EED8F6B5C5610B2" ;;
        modules/lwjgl/opengles/src/generated/c/org_lwjgl_opengles_GLES20.c)
            echo "005BD3FD1E69E5119341C0E61D8AF5074DA86D239285F5582C15A09D910F223C" ;;
        *)
            echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 3b. Symbols the compiled liblwjgl.so objects require from libffi.
#
#     Extracted from the real object files (llvm-nm --undefined-only) and used
#     to turn a confusing link failure into an actionable error message. Note
#     that ffi_get_version / ffi_get_version_number / ffi_get_default_abi /
#     ffi_get_closure_size only exist from libffi 3.5.0 onwards.
# ---------------------------------------------------------------------------

required_ffi_symbols() {
    cat <<'EOF'
ffi_call
ffi_closure_alloc
ffi_closure_free
ffi_get_closure_size
ffi_get_default_abi
ffi_get_struct_offsets
ffi_get_version
ffi_get_version_number
ffi_prep_cif
ffi_prep_cif_var
ffi_prep_closure_loc
ffi_type_double
ffi_type_float
ffi_type_longdouble
ffi_type_pointer
ffi_type_sint16
ffi_type_sint32
ffi_type_sint64
ffi_type_sint8
ffi_type_uint16
ffi_type_uint32
ffi_type_uint64
ffi_type_uint8
ffi_type_void
EOF
}

# ---------------------------------------------------------------------------
# 4. ABI table
#
#    `<abi>`         Android ABI name (also used in artifact file names)
#    lwjgl_arch      LWJGL architecture token, used for -DLWJGL_<arch> and for
#                    the resource directory linux/<arch>/  (LWJGL's own naming)
#    ndk_triple      NDK clang wrapper prefix (without the API level)
#    libffi_host     --host triple handed to libffi's configure
#    ffi_inc         sub directory of modules/lwjgl/core/src/main/c/libffi
# ---------------------------------------------------------------------------

ALL_ABIS=(arm64-v8a armeabi-v7a x86_64)

abi_supported() {
    case "$1" in
        arm64-v8a|armeabi-v7a|x86_64) return 0 ;;
        *) return 1 ;;
    esac
}

abi_lwjgl_arch() {
    case "$1" in
        arm64-v8a)   echo "arm64" ;;
        armeabi-v7a) echo "arm32" ;;
        x86_64)      echo "x64" ;;
        *) die "unknown ABI: $1" ;;
    esac
}

abi_ndk_triple() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7a-linux-androideabi" ;;
        x86_64)      echo "x86_64-linux-android" ;;
        *) die "unknown ABI: $1" ;;
    esac
}

abi_libffi_host() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "arm-linux-androideabi" ;;
        x86_64)      echo "x86_64-linux-android" ;;
        *) die "unknown ABI: $1" ;;
    esac
}

abi_ffi_include_dir() {
    case "$1" in
        arm64-v8a)   echo "aarch64" ;;
        armeabi-v7a) echo "arm" ;;
        x86_64)      echo "x86" ;;
        *) die "unknown ABI: $1" ;;
    esac
}

# Extra preprocessor definitions required by LWJGL's vendored libffi headers.
# libffi/x86/ffitarget.h selects the UNIX64 ABI under `#elif defined(X86_64) ||
# (defined(__x86_64__) && defined(X86_DARWIN))`; plain Android x86_64 defines
# neither, so X86_64 has to be forced (LWJGL's own Ant build does the same).
abi_extra_defines() {
    case "$1" in
        x86_64) echo "-DX86_64" ;;
        *)      echo "" ;;
    esac
}

# Human readable description used in BUILD-INFO.txt / release notes.
abi_description() {
    case "$1" in
        arm64-v8a)   echo "ARM 64-bit (aarch64), android-${ANDROID_API}" ;;
        armeabi-v7a) echo "ARM 32-bit (armv7-a / VFP), android-${ANDROID_API}" ;;
        x86_64)      echo "x86 64-bit (x86_64), android-${ANDROID_API}" ;;
        *) die "unknown ABI: $1" ;;
    esac
}

# ---------------------------------------------------------------------------
# 5. Logging helpers
# ---------------------------------------------------------------------------

info() { printf '\033[1;34m[build]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}
