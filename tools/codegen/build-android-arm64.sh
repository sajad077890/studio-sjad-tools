#!/usr/bin/env bash
set -euo pipefail

# Build the real CPython + Glean Parser + Mozilla Nimbus FML tools for Android ARM64.
# Required environment: ANDROID_HOME, ANDROID_NDK_HOME, GLEAN_PARSER_VERSION.
# Optional: NIMBUS_FML_REF=main, CPYTHON_REF=3.13, ANDROID_API=21.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${GLEAN_PARSER_VERSION:?Set GLEAN_PARSER_VERSION to the version required by the Glean plugin used by the project}"
NIMBUS_FML_REF="${NIMBUS_FML_REF:-main}"
CPYTHON_REF="${CPYTHON_REF:-3.13}"
ANDROID_API="${ANDROID_API:-21}"
TARGET="aarch64-linux-android"
ABI="arm64-v8a"
WORK="${CODEGEN_WORK_DIR:-$ROOT/.codegen-build}"
STAGE="$WORK/stage/$ABI"
DIST="$WORK/dist"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "$SDK" && -d "$SDK" ]] || { echo "ANDROID_HOME/ANDROID_SDK_ROOT is missing" >&2; exit 2; }
NDK="${ANDROID_NDK_HOME:-}"
if [[ -z "$NDK" ]]; then
  NDK="$(find "$SDK/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || { echo "Android NDK not found" >&2; exit 2; }
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
LINKER="$TC/${TARGET}${ANDROID_API}-clang"
[[ -x "$LINKER" ]] || { echo "NDK linker missing: $LINKER" >&2; exit 2; }
for tool in cargo rustup git readelf zip python3; do
  command -v "$tool" >/dev/null || { echo "Required command not found: $tool" >&2; exit 2; }
done

rm -rf "$WORK"
mkdir -p "$WORK/src" "$STAGE/bin" "$DIST"

# 1. Build Mozilla's actual nimbus-fml command line program for Android ARM64.
NIMBUS_DIR="$WORK/src/application-services"
git clone --depth 1 https://github.com/mozilla/application-services.git "$NIMBUS_DIR"
git -C "$NIMBUS_DIR" fetch --depth 1 origin "$NIMBUS_FML_REF"
git -C "$NIMBUS_DIR" checkout --detach FETCH_HEAD
NIMBUS_MANIFEST="$NIMBUS_DIR/components/support/nimbus-fml/Cargo.toml"
[[ -f "$NIMBUS_MANIFEST" ]] || { echo "nimbus-fml Cargo.toml not found for ref $NIMBUS_FML_REF" >&2; exit 3; }

rustup target add "$TARGET"
export ANDROID_NDK_HOME="$NDK"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$LINKER"
export CC_aarch64_linux_android="$LINKER"
export CXX_aarch64_linux_android="$TC/${TARGET}${ANDROID_API}-clang++"
export AR_aarch64_linux_android="$TC/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$TC/llvm-ar"
export CFLAGS_aarch64_linux_android="--target=${TARGET}${ANDROID_API}"
export CXXFLAGS_aarch64_linux_android="--target=${TARGET}${ANDROID_API}"
cargo build --manifest-path "$NIMBUS_MANIFEST" --bin nimbus-fml --target "$TARGET" --release --locked
NIMBUS_BIN="$NIMBUS_DIR/target/$TARGET/release/nimbus-fml"
[[ -x "$NIMBUS_BIN" ]] || { echo "Cargo did not produce nimbus-fml" >&2; exit 4; }
readelf -h "$NIMBUS_BIN" | grep -q 'Machine:.*AArch64' || { echo "nimbus-fml is not AArch64 ELF" >&2; exit 4; }
install -m 700 "$NIMBUS_BIN" "$STAGE/bin/nimbus-fml"

# 2. Build an Android ARM64 CPython runtime using CPython's official Android builder.
CPYTHON_DIR="$WORK/src/cpython"
git clone --depth 1 --branch "$CPYTHON_REF" https://github.com/python/cpython.git "$CPYTHON_DIR"
(
  cd "$CPYTHON_DIR"
  export ANDROID_HOME="$SDK" ANDROID_NDK_HOME="$NDK"
  python3 Platforms/Android build "$TARGET" -- --enable-shared
)
PY_PREFIX="$CPYTHON_DIR/cross-build/$TARGET/prefix"
[[ -d "$PY_PREFIX/lib" ]] || { echo "CPython Android prefix not found: $PY_PREFIX" >&2; exit 5; }
PY_VER="$(find "$PY_PREFIX/lib" -mindepth 1 -maxdepth 1 -type d -name 'python3.*' -printf '%f\n' | head -1)"
[[ -n "$PY_VER" ]] || { echo "CPython standard library not found" >&2; exit 5; }
PY_MINOR="${PY_VER#python}"
cp -aL "$PY_PREFIX/." "$STAGE/"
mkdir -p "$STAGE/bin"
PY_INC="$PY_PREFIX/include/$PY_VER"
PY_LIB="$(find "$PY_PREFIX/lib" -maxdepth 1 \( -type f -o -type l \) -name 'libpython*.so*' -print | sort | head -1)"
[[ -d "$PY_INC" && -n "$PY_LIB" ]] || { echo "CPython headers or libpython missing" >&2; exit 5; }
LIB_FILE="$(basename "$PY_LIB")"
if [[ "$LIB_FILE" == *.so ]]; then
  PY_LIB_LINK="$PY_LIB"
else
  LIB_STEM="${LIB_FILE%%.so*}"
  PY_LIB_LINK="$PY_PREFIX/lib/$LIB_STEM.so"
  ln -sf "$LIB_FILE" "$PY_LIB_LINK"
fi
LIB_NAME="$(basename "$PY_LIB_LINK" .so)"
LIB_NAME="${LIB_NAME#lib}"
"$LINKER" -fPIE -pie -I"$PY_INC" "$ROOT/tools/codegen/python_launcher.c" \
  -L"$PY_PREFIX/lib" -Wl,-rpath,'$ORIGIN/../lib' -l"$LIB_NAME" \
  -o "$STAGE/bin/python3"
chmod 700 "$STAGE/bin/python3"

# 3. Install Glean Parser and its Python dependencies as Python source only.
# This deliberately strips host .so files: Android-native C extensions must never be copied
# from the Ubuntu runner. PyYAML, MarkupSafe and pyrsistent are built into host wheels only
# to obtain their pure-Python modules; their host binary extensions are omitted.
PURE_WHEELS="$WORK/pure-wheels"
HOST_WHEELS="$WORK/host-wheels"
SITE="$STAGE/lib/$PY_VER/site-packages"
mkdir -p "$PURE_WHEELS" "$HOST_WHEELS" "$SITE"
python3 -m pip install --upgrade pip setuptools wheel Cython
python3 -m pip download --no-deps --only-binary=:all: \
  --dest "$PURE_WHEELS" --platform any --implementation py --python-version "$PY_MINOR" --abi none \
  "glean-parser==$GLEAN_PARSER_VERSION" \
  "click==8.3.1" "diskcache==5.6.3" "Jinja2==3.1.6" \
  "jsonschema==4.17.3" "platformdirs==4.5.0" "attrs==25.4.0" "six==1.17.0"
python3 -m pip wheel --no-deps --no-build-isolation --no-binary=PyYAML,MarkupSafe,pyrsistent \
  --wheel-dir "$HOST_WHEELS" "PyYAML==6.0.3" "MarkupSafe==3.0.3" "pyrsistent==0.20.0"

python3 - "$PURE_WHEELS" "$HOST_WHEELS" "$SITE" <<'PY'
import pathlib, sys, zipfile
pure, host, site = map(pathlib.Path, sys.argv[1:])
site.mkdir(parents=True, exist_ok=True)
for source in (pure, host):
    wheels = sorted(source.glob('*.whl'))
    if not wheels:
        raise SystemExit(f'No wheels produced in {source}')
    for wheel in wheels:
        with zipfile.ZipFile(wheel) as archive:
            for info in archive.infolist():
                name = info.filename
                if info.is_dir() or name.endswith(('.so', '.pyd', '.dll', '.dylib')):
                    continue
                if name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts:
                    raise SystemExit(f'Unsafe wheel path: {name}')
                target = site.joinpath(*pathlib.PurePosixPath(name).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(info))
        print('installed Python-only files from', wheel.name)
PY

# Smoke-test Python imports on the build host with only the staged pure-Python modules.
PYTHONPATH="$SITE" python3 - <<'PY'
import click, diskcache, jinja2, jsonschema, markupsafe, platformdirs, yaml, glean_parser
print('Glean/Python dependency import smoke test: OK')
PY
PYTHONPATH="$SITE" python3 -m glean_parser --help >/dev/null

# 4. Validate every executable and every shared library that will be shipped.
for exe in "$STAGE/bin/python3" "$STAGE/bin/nimbus-fml"; do
  readelf -h "$exe" | grep -q 'Machine:.*AArch64' || { echo "Not Android ARM64 ELF: $exe" >&2; exit 7; }
done
if find "$SITE" -type f \( -name '*.so' -o -name '*.pyd' -o -name '*.dll' -o -name '*.dylib' \) | grep -q .; then
  echo "Unexpected native host extension found in Python site-packages" >&2; exit 8
fi
while IFS= read -r -d '' so; do
  readelf -h "$so" | grep -q 'Machine:.*AArch64' || { echo "Non-ARM64 shared library: $so" >&2; exit 9; }
done < <(find "$STAGE/lib" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)

# 5. Create the manifest consumed by Studio Sajad's runtime verifier.
python3 - "$STAGE" "$NIMBUS_FML_REF" "$CPYTHON_REF" "$GLEAN_PARSER_VERSION" "$ANDROID_API" "$PY_VER" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
required = ['bin/python3', 'bin/nimbus-fml']
files = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in required}
native = {}
for path in sorted((root / 'lib').rglob('*')):
    if path.is_file() and (path.name.endswith('.so') or '.so.' in path.name):
        native[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {
    'schema': 1, 'abi': 'arm64-v8a', 'androidApi': int(sys.argv[5]),
    'nimbusFmlRef': sys.argv[2], 'cpythonRef': sys.argv[3],
    'pythonVersion': sys.argv[6], 'gleanParserVersion': sys.argv[4],
    'filesSha256': files, 'nativeLibrariesSha256': native,
}
(root / 'toolchain-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY

mkdir -p "$DIST"
(cd "$WORK/stage" && zip -qr "$DIST/studio-codegen-android-arm64.zip" "$ABI")
(cd "$DIST" && sha256sum studio-codegen-android-arm64.zip > studio-codegen-android-arm64.zip.sha256)
echo "SUCCESS: $DIST/studio-codegen-android-arm64.zip"
echo "SUCCESS: $DIST/studio-codegen-android-arm64.zip.sha256"
