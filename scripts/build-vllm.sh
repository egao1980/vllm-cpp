#!/usr/bin/env bash
# Build mudler/vllm.cpp shared lib into lib/<os>-<arch>[-flavor]/.
# Env: VLLM_CPP_REF (default master), VLLM_CPP_FLAVOR=cpu|cuda|mlx,
#      VLLM_CPP_CUDA_ARCHITECTURES, MLX_ROOT, DEST_DIR, JOBS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${VLLM_CPP_REF:-master}"
FLAVOR="${VLLM_CPP_FLAVOR:-cpu}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
SRC_URL="https://github.com/mudler/vllm.cpp.git"

uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS: $uname_s" >&2; exit 1 ;;
esac
case "$uname_m" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported arch: $uname_m" >&2; exit 1 ;;
esac

case "$FLAVOR" in
  cpu|cuda|mlx) ;;
  *) echo "VLLM_CPP_FLAVOR must be cpu|cuda|mlx (got: $FLAVOR)" >&2; exit 1 ;;
esac

if [[ "$FLAVOR" == "cpu" ]]; then
  suffix=""
else
  suffix="-${FLAVOR}"
fi
OUT="${DEST_DIR:-$ROOT/lib/${os}-${arch}${suffix}}"
SRC="$ROOT/build/vllm.cpp"
BUILD="$ROOT/build/${os}-${arch}${suffix}"

mkdir -p "$ROOT/build"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch --depth 1 origin "$REF"
  git -C "$SRC" checkout --force FETCH_HEAD
else
  rm -rf "$SRC"
  git clone --depth 1 --branch "$REF" "$SRC_URL" "$SRC" \
    || { git clone --depth 1 "$SRC_URL" "$SRC" && git -C "$SRC" checkout --force "$REF"; }
fi

cmake_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=ON
  -DVLLM_CPP_BUILD_TESTS=OFF
  -DVLLM_CPP_BUILD_EXAMPLES=OFF
  -DVLLM_CPP_SERVER=OFF
)

case "$FLAVOR" in
  cpu)
    cmake_args+=(-DVLLM_CPP_CUDA=OFF -DVLLM_CPP_MLX=OFF)
    if [[ "$os" == "darwin" ]]; then
      cmake_args+=(-DVLLM_CPP_METAL=ON)
    fi
    ;;
  cuda)
    cmake_args+=(-DVLLM_CPP_CUDA=ON -DVLLM_CPP_CUTLASS_FETCH=ON)
    if [[ -n "${VLLM_CPP_CUDA_ARCHITECTURES:-}" ]]; then
      cmake_args+=(-DVLLM_CPP_CUDA_ARCHITECTURES="${VLLM_CPP_CUDA_ARCHITECTURES}")
    fi
    ;;
  mlx)
    if [[ "$os" != "darwin" ]]; then
      echo "mlx flavor is darwin-only" >&2
      exit 1
    fi
    if [[ -z "${MLX_ROOT:-}" ]]; then
      echo "MLX_ROOT must point at an MLX install (include/ + lib/)" >&2
      exit 1
    fi
    cmake_args+=(-DVLLM_CPP_METAL=ON -DVLLM_CPP_MLX=ON -DMLX_ROOT="${MLX_ROOT}")
    ;;
esac

echo "==> cmake vllm.cpp ${REF} flavor=${FLAVOR} -> ${OUT}"
cmake -S "$SRC" -B "$BUILD" "${cmake_args[@]}"
cmake --build "$BUILD" -j"$JOBS"

rm -rf "$OUT"
mkdir -p "$OUT"
shopt -s nullglob
libs=(
  "$BUILD"/libvllm.so*
  "$BUILD"/libvllm*.dylib
  "$BUILD"/lib/libvllm.so*
  "$BUILD"/lib/libvllm*.dylib
  "$BUILD"/src/libvllm.so*
  "$BUILD"/src/libvllm*.dylib
)
# cmake sometimes lands the shared lib next to the target.
while IFS= read -r -d '' f; do
  libs+=("$f")
done < <(find "$BUILD" -name 'libvllm.so*' -o -name 'libvllm*.dylib' -print0 2>/dev/null || true)

if ((${#libs[@]} == 0)); then
  echo "libvllm shared library not found under $BUILD" >&2
  find "$BUILD" -name '*vllm*' | head -50 >&2 || true
  exit 1
fi
cp -a "${libs[@]}" "$OUT/"
echo "staged:" && ls -la "$OUT"
