#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Package the staged natives of one ABI into a release archive.
#
#   <outdir>/lwjgl-<lwjgl version>-android-<abi>.zip
#   <outdir>/lwjgl-<lwjgl version>-android-<abi>.zip.sha256
#
# The file name is stable on purpose: it contains no build counter, so the
# download URL can be hard-coded by consumers.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") --abi <abi> --indir <staging dir> --outdir <dist dir>

Options:
  --abi <abi>        one of: ${ALL_ABIS[*]}
  --indir <dir>      staging directory produced by build.sh (default: dist)
  --outdir <dir>     directory the archive is written to (default: release)
  -h, --help         show this help
EOF
}

ABI=""
INDIR="dist"
OUTDIR="release"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --abi)    ABI="$2";    shift 2 ;;
        --indir)  INDIR="$2";  shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$ABI" ]] || { usage >&2; die "--abi is required"; }
abi_supported "$ABI" || die "unsupported ABI '$ABI'"

require_cmd zip

LWJGL_ARCH="$(abi_lwjgl_arch "$ABI")"

[[ -d "$INDIR" ]] || die "staging directory not found: $INDIR"
INDIR="$(cd "$INDIR" && pwd)"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

STAGE_DIR="$INDIR/linux/$LWJGL_ARCH"
[[ -d "$STAGE_DIR/org/lwjgl" ]] || die "staged natives not found: $STAGE_DIR/org/lwjgl"

ARCHIVE_NAME="lwjgl-${LWJGL_VERSION}-android-${ABI}.zip"
ARCHIVE="$OUTDIR/$ARCHIVE_NAME"

PKG_ROOT="$(mktemp -d)"
trap 'rm -rf "$PKG_ROOT"' EXIT

# The archive layout mirrors LWJGL's natives-jar resource tree.
# Only this ABI's tree is copied, so a shared --indir used for several ABIs is safe.
mkdir -p "$PKG_ROOT/linux"
cp -r "$STAGE_DIR" "$PKG_ROOT/linux/$LWJGL_ARCH"
if [[ -f "$INDIR/BUILD-INFO.txt" ]]; then
    cp "$INDIR/BUILD-INFO.txt" "$PKG_ROOT/BUILD-INFO.txt"
fi

cat >"$PKG_ROOT/README.txt" <<EOF
LWJGL $LWJGL_VERSION natives for Android - $ABI
============================================

Drop-in replacement for the LWJGL "$LWJGL_ARCH" native resource tree.

Layout:
    linux/$LWJGL_ARCH/org/lwjgl/liblwjgl.so
    linux/$LWJGL_ARCH/org/lwjgl/opengles/liblwjgl_opengles.so

Target: Android API $ANDROID_API (minSdk 30), NDK $NDK_VERSION
Built with: LWJGL $LWJGL_COMMIT, libffi $LIBFFI_VERSION ($LIBFFI_COMMIT)

The debug information is retained; the libraries are not stripped.

ANGLE (libEGL_angle.so / libGLESv2_angle.so / libGLESv1_CM_angle.so) is NOT
included - those are Android platform prebuilts and must be supplied
separately under linux/$LWJGL_ARCH/.
EOF

rm -f "$ARCHIVE"
( cd "$PKG_ROOT" && zip -r -X -q "$ARCHIVE" . )

HASH="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$ARCHIVE" | cut -d' ' -f1; else shasum -a 256 "$ARCHIVE" | cut -d' ' -f1; fi)"
printf '%s  %s\n' "$HASH" "$ARCHIVE_NAME" >"$ARCHIVE.sha256"

info "packaged $ARCHIVE_NAME"
info "  size   : $(du -h "$ARCHIVE" | cut -f1)"
info "  sha256 : $HASH"
