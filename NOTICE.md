# Third-party notices

This repository does not contain third-party sources. It downloads, verifies and builds the components listed below at the exact revisions pinned in `scripts/common.sh`.

---

## LWJGL 3.4.1

- Project: <https://www.lwjgl.org/>
- Source: <https://github.com/LWJGL/lwjgl3>
- Revision: `b800ccffab14396fc529ddb6c931b7c5c5226763` (tag `3.4.1`)
- Copyright: Copyright (c) 2012-2026 LWJGL
- License: BSD 3-Clause — <https://www.lwjgl.org/license>

Modules compiled into the produced binaries:

| Module | Sources | Output |
| --- | --- | --- |
| `lwjgl` (core) | `modules/lwjgl/core/src` | `org/lwjgl/liblwjgl.so` |
| `lwjgl-opengles` | `modules/lwjgl/opengles/src` | `org/lwjgl/opengles/liblwjgl_opengles.so` |

The core module additionally embeds these bundled third-party sources:

### miniz 3.0.0

- File: `modules/lwjgl/core/src/main/c/dependencies/miniz/miniz.c`
- Copyright: Copyright 2013-2014 RAD Game Tools and Valve Software
- Copyright: Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC
- License: MIT

### liburing 2.x headers / sources

- Path: `modules/lwjgl/core/src/main/c/linux/liburing/`
- **Not compiled into the produced binaries.** `LibURing.c` and `LibIOURing.c` are explicitly excluded because io_uring is a kernel-only interface that Android applications cannot use. The headers are still present in the source tree, which is why the license is listed here.
- License: MIT / LGPL-2.1 (dual)

---

## libffi 3.5.0

- Project: <https://github.com/libffi/libffi>
- Revision: `d2c78d2ebbd9e65401095c6a2f281fe5132f028b` (tag `v3.5.0`)
- Copyright: Copyright (c) 1996-2020 Anthony Green, Red Hat, Inc and others
- License: MIT — see `modules/lwjgl/core/libffi_license.txt` in the LWJGL tree

Built from source as a static archive (`libffi.a`) for each target ABI and statically linked into `liblwjgl.so`.

**The version is not arbitrary.** LWJGL 3.4.1 compiles its generated libffi bindings against the vendored `modules/lwjgl/core/src/main/c/libffi/ffi.h`, which hard-codes:

```c
#define FFI_VERSION_STRING "3.5.0"
#define FFI_VERSION_NUMBER 30500
#define FFI_TYPE_LAST      FFI_TYPE_COMPLEX
```

libffi 3.6.0 introduced `FFI_TYPE_UINT128` / `FFI_TYPE_SINT128`, which changes `FFI_TYPE_LAST` and breaks that contract. `scripts/build.sh` therefore verifies at build time that the produced `libffi.a` exports every symbol the LWJGL objects require (see `required_ffi_symbols` in `scripts/common.sh`).

---

## Android NDK 29.0.14206865

- Project: <https://developer.android.com/ndk>
- License: Android NDK License — <https://developer.android.com/ndk/downloads>

Used as the cross-compilation toolchain (clang 21 / LLD 21). Not redistributed by this repository; the CI workflow installs it through `sdkmanager`.

The NDK sysroot also supplies the `jni.h` used to compile the LWJGL sources, so no JDK headers are needed.

---

## ANGLE (not included)

`libEGL_angle.so`, `libGLESv2_angle.so` and `libGLESv1_CM_angle.so` are **not** built or bundled here. They are Google's ANGLE, compiled by the Android platform build system (API 34) and shipped inside Android images.

- Project: <https://chromium.googlesource.com/angle/angle>
- License: BSD 3-Clause

Anyone packaging them alongside the libraries produced by this repository is responsible for obtaining them lawfully from a device/ROM image and for complying with the applicable redistribution terms.

---

## This repository

The build scripts and workflow in this repository do not carry a license declaration yet. Add a `LICENSE` file before publishing if you intend others to reuse them.
