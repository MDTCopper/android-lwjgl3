# android-lwjgl3

Builds the **LWJGL 3.4.1** native libraries for **Android** from upstream source, using a pinned Android NDK, and publishes one archive per ABI.

- **No ANGLE.** `libEGL_angle.so`, `libGLESv2_angle.so` and `libGLESv1_CM_angle.so` are Android platform prebuilts; this repository neither builds nor bundles them (see [About ANGLE](#about-angle)).
- **No source patches.** LWJGL's Linux C backend is already plain POSIX, so the Android port lives entirely in the build configuration (see [Deviations from the upstream build](#deviations-from-the-upstream-build)).

---

## Outputs

One archive per ABI. File names are **stable** (no build counter), so download URLs can be hard-coded:

| ABI | Archive | Resource path inside |
| --- | --- | --- |
| `arm64-v8a` | `lwjgl-3.4.1-android-arm64-v8a.zip` | `linux/arm64/org/lwjgl/` |
| `armeabi-v7a` | `lwjgl-3.4.1-android-armeabi-v7a.zip` | `linux/arm32/org/lwjgl/` |
| `x86_64` | `lwjgl-3.4.1-android-x86_64.zip` | `linux/x64/org/lwjgl/` |

Contents of each archive:

```text
linux/<arch>/org/lwjgl/liblwjgl.so
linux/<arch>/org/lwjgl/opengles/liblwjgl_opengles.so
BUILD-INFO.txt          # full provenance of this archive
README.txt
```

> The directory names use **LWJGL's own architecture tokens** (`arm64`, `arm32`, `x64`). This is the layout LWJGL's native loader expects (the official `natives-linux.jar` uses `linux/x64/...`), so it is not interchangeable with Android ABI names such as `arm64-v8a` or `x86_64`.

Two properties worth knowing about the artifacts:

- They are **not stripped** and no linker version script is applied, so the full DWARF debug information and every symbol are retained.
- They carry no `META-INF/**/*.so.sha1` sidecars, unlike LWJGL's own natives jars, so LWJGL's native library hash verification has to be disabled by the consumer.

## Download

Releases are named after the **LWJGL version** (both the tag and the release title are `3.4.1`), which keeps the URLs stable:

```text
https://github.com/MDTCopper/android-lwjgl3/releases/download/3.4.1/lwjgl-3.4.1-android-arm64-v8a.zip
https://github.com/MDTCopper/android-lwjgl3/releases/download/3.4.1/lwjgl-3.4.1-android-armeabi-v7a.zip
https://github.com/MDTCopper/android-lwjgl3/releases/download/3.4.1/lwjgl-3.4.1-android-x86_64.zip
https://github.com/MDTCopper/android-lwjgl3/releases/download/3.4.1/SHA256SUMS.txt
```

The release notes list every component version and revision, and embed the full `BUILD-INFO.txt` of each ABI.

## Building

### On GitHub Actions

The workflow is **manual only** — pushing never starts a build. Run *Build LWJGL natives for Android* from the Actions tab; leave `publish_release` ticked to refresh the release, or untick it to build artifacts without touching a release.

The three ABIs are built in parallel on separate runners; only after all of them succeed does the `release` job collect the archives, write `SHA256SUMS.txt` and publish the release named after the LWJGL version.

The NDK is **not downloaded**: GitHub's Ubuntu images already install `29.0.14206865` inside the Android SDK at `<sdk>/ndk/<revision>`, and the workflow verifies `Pkg.Revision` before building. Those images also export `ANDROID_NDK_HOME` for a different default revision; that one is ignored. A standalone NDK zip is only fetched as a fallback if a future image stops shipping the pinned revision.

### Locally

Requirements: `git`, `make`, `tar`, `curl`, `zip`, and NDK `29.0.14206865`. No autotools are needed: libffi comes from its release tarball, which ships a pre-generated `configure`. `build.sh` searches `NDK_HOME`, `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` and `<sdk>/ndk/<revision>`, and rejects any candidate whose `source.properties` does not report `Pkg.Revision = 29.0.14206865` (set `SKIP_NDK_VERSION_CHECK=1` to override).

```bash
export ANDROID_SDK_ROOT=/path/to/android-sdk     # containing ndk/29.0.14206865
# or: export NDK_HOME=/path/to/android-ndk-r29

./scripts/build.sh   --abi arm64-v8a --outdir dist
./scripts/package.sh --abi arm64-v8a --indir dist --outdir release
```

`--abi` accepts `arm64-v8a`, `armeabi-v7a` or `x86_64`.

Other options:

```text
--workdir <dir>   scratch directory for sources, libffi and objects (default: ./build)
--jobs <n>        parallel compile jobs (default: number of CPUs)
--werror          treat compiler warnings as errors
```

> `--werror` currently trips on two benign warnings that also occur upstream: an incompatible pointer type in LWJGL's `common_tools.c`, and a miniz `#pragma message` about large-file I/O.

## Build configuration

| Setting | Value |
| --- | --- |
| Target platform | Android (bionic), not glibc |
| Android API level (minSdk) | **30 (Android 11)** |
| NDK | **29.0.14206865** (clang 21 / LLD 21) |
| ABIs | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| LWJGL modules | `lwjgl` (core, includes EGL bindings), `lwjgl-opengles` |
| Optimisation | `-O3`; DWARF debug info retained, **not stripped** |
| Linking | no version script; all symbols exported |
| Runtime dependencies | bionic `libc`, `libdl`, `libm` only |

Compile flags, mirroring LWJGL's `config/linux/build.xml`:

```text
-c -std=gnu11 -O3 -fPIC -pthread -DNDEBUG
-DLWJGL_LINUX -DLWJGL_<arch>
-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64
-Wall -Wextra -g
```

`jni.h` is taken from the NDK sysroot, so no JDK include directory is needed.

## Deviations from the upstream build

"Upstream" means LWJGL's own Ant native build (`config/linux/build.xml`). Every difference is a **build configuration** change; no LWJGL source file is modified.

| # | Deviation | Why |
| --- | --- | --- |
| 1 | `libffi.a` is built here from libffi 3.5.0 source with the NDK | Upstream downloads a **glibc** prebuilt from `build.lwjgl.org`, which cannot be used on Android |
| 2 | `miniz.c` is compiled into `liblwjgl.so` | Upstream's Ant `core` target does not list it among its sources |
| 3 | `linux/UIO.c`, `linux/liburing_LibIOURing.c` and `linux/liburing_LibURing.c` are excluded | io_uring / UIO are kernel-only interfaces that Android applications cannot use |
| 4 | No `version.script`, and the output is not stripped | Keeps every symbol exported and the DWARF intact for crash symbolication |
| 5 | `-flto=auto` is not used | `=auto` is a GCC-only spelling that clang does not accept |
| 6 | `-llog` is not linked | It is a redundant dependency: `liblwjgl.so` contains no `__android_log_*` reference at all. LLD defaults to `--no-as-needed`, so an explicit `-llog` is retained even when unused — which is exactly why some existing builds show it |
| 7 | minSdk is **30** | Project requirement (Android 11) |
| 8 | `x86_64` is built as well | Project requirement |

Note on #6: earlier hand-made arm64 artifacts carried a redundant `liblog.so` `NEEDED` entry. That is a linker artefact, not evidence of an Android logging patch — the symbol tables, DWARF function inventory and per-function declaration lines of those binaries match upstream 3.4.1 exactly.

## Pinned versions and provenance

Every upstream input is pinned and verified during the build; any mismatch fails the build immediately.

| Component | Version | Pinned by |
| --- | --- | --- |
| LWJGL | 3.4.1 | git tag, verified against commit `b800ccffab14396fc529ddb6c931b7c5c5226763` |
| libffi | 3.5.0 | release tarball, verified against SHA-256 `8c72678628a5dd8782f08ad421d5a441e42c1c5c1b33e0bc211cbfcf1f3b3978` |
| Android NDK | 29.0.14206865 | `Pkg.Revision` in `source.properties` |

libffi is taken from its **release tarball** rather than a git checkout because libffi 3.5.0's `configure.ac` requires autoconf ≥ 2.72, while the CI images ship 2.71 (Ubuntu 22.04 and 24.04 both), so `autoreconf` cannot regenerate `./configure` there. The tarball carries a maintainer-generated `configure`, and its sources were compared file by file against tag `v3.5.0` (`d2c78d2ebbd9e65401095c6a2f281fe5132f028b`) and match byte for byte.

In addition to those checks, specific LWJGL files the recipe depends on are verified by SHA-256 (see `pin_paths` / `pin_sha256` in `scripts/common.sh`), and the number of translation units is asserted (24 for core, 135 for OpenGL ES), so upstream drift fails loudly instead of silently changing the output.

**The libffi version must not be bumped casually.** LWJGL 3.4.1 vendors its own `ffi.h`, which hard-codes:

```c
#define FFI_VERSION_STRING "3.5.0"
#define FFI_VERSION_NUMBER 30500
#define FFI_TYPE_LAST      FFI_TYPE_COMPLEX
```

libffi 3.6.0 added `FFI_TYPE_UINT128` / `FFI_TYPE_SINT128`, which changes `FFI_TYPE_LAST` and the ABI. `scripts/build.sh` therefore checks that the built `libffi.a` actually exports all 24 symbols the LWJGL objects require.

### Upgrading LWJGL

1. Update `LWJGL_VERSION` and `LWJGL_COMMIT` in `scripts/common.sh`.
2. If `modules/lwjgl/core/src/main/c/libffi/ffi.h` changed, re-derive the libffi version from the `FFI_VERSION_STRING` / `FFI_VERSION_NUMBER` it declares, then update `LIBFFI_TARBALL_URL`, `LIBFFI_TARBALL_SHA256` and `LIBFFI_COMMIT` in `scripts/common.sh`.
3. Refresh `pin_paths` / `pin_sha256` with `sha256sum`.
4. Adjust the translation-unit count assertions in `scripts/build.sh` if sources were added or removed.
5. Update the default `lwjgl_version` of the `workflow_dispatch` input in `.github/workflows/build.yml`.

## About ANGLE

ANGLE is **not** built or packaged here. `libEGL_angle.so`, `libGLESv2_angle.so` and `libGLESv1_CM_angle.so` come from Google's ANGLE **platform** build for Android: their `.note.android.ident` records only an API level and no NDK version, and they bind bionic's `LIBC_N` / `LIBC_O` / `LIBC_R` symbol versions. They have to be obtained from a device or ROM image and placed next to these libraries:

```text
linux/<arch>/libEGL_angle.so
linux/<arch>/libGLESv2_angle.so
linux/<arch>/libGLESv1_CM_angle.so
```

LWJGL reaches them through `Configuration.EGL_LIBRARY_NAME` and `Configuration.OPENGLES_LIBRARY_NAME`.

## Repository layout

```text
scripts/common.sh            pinned versions, ABI table, NDK discovery, symbol pins
scripts/build.sh             fetch + verify sources -> build libffi -> compile -> link -> BUILD-INFO.txt
scripts/package.sh           package one ABI into a stable-named zip plus .sha256
.github/workflows/build.yml  CI: per-ABI matrix build, then checksum and release
NOTICE.md                    third-party components, revisions and licenses
```

## Acknowledgements

Thanks to the [**oxygen-launcher-api**](https://github.com/EmmmM9O/oxygen-launcher-api) project, which defined the resource layout these archives target and provided the reference artifacts this build recipe was reconstructed from.

## License

- **LWJGL**: BSD 3-Clause — <https://www.lwjgl.org/license>
- **libffi**: MIT

The build scripts in this repository do not declare a license yet; add a `LICENSE` file before publishing if others are meant to reuse them.

See [NOTICE.md](./NOTICE.md) for the full third-party notices.
