#!/usr/bin/env bash
# Build mudler/vllm.cpp shared lib into lib/<os>-<arch>/.
# Linux default is CUDA (the published linux/amd64 overlay). CPU is
# VLLM_CPP_FLAVOR=cpu for local no-GPU boxes only — OCI linux/amd64 is CUDA.
# Env: VLLM_CPP_REF, VLLM_CPP_FLAVOR=cuda|cpu|mlx,
#      VLLM_CPP_CUDA_ARCHITECTURES (default 80;86;89;90a), MLX_ROOT, DEST_DIR, JOBS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${VLLM_CPP_REF:-main}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
SRC_URL="https://github.com/mudler/vllm.cpp.git"

uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_s" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    if command -v pwsh >/dev/null 2>&1; then
      exec pwsh -File "$ROOT/scripts/build-vllm.ps1"
    fi
    if command -v powershell >/dev/null 2>&1; then
      exec powershell -File "$ROOT/scripts/build-vllm.ps1"
    fi
    echo "Windows build needs pwsh (scripts/build-vllm.ps1)" >&2
    exit 1
    ;;
  *) echo "unsupported OS: $uname_s" >&2; exit 1 ;;
esac
case "$uname_m" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "unsupported arch: $uname_m" >&2; exit 1 ;;
esac

if [[ -z "${VLLM_CPP_FLAVOR:-}" ]]; then
  if [[ "$os" == "linux" ]]; then
    FLAVOR=cuda
  else
    FLAVOR=cpu
  fi
else
  FLAVOR="$VLLM_CPP_FLAVOR"
fi

case "$FLAVOR" in
  cpu|cuda|mlx) ;;
  *) echo "VLLM_CPP_FLAVOR must be cuda|cpu|mlx (got: $FLAVOR)" >&2; exit 1 ;;
esac

# Published overlay path is lib/<os>-<arch>/. Extra local flavors get a suffix
# so they cannot clobber the OCI layout (arrange-native-artifacts is os-arch only).
if [[ "$FLAVOR" == "cpu" && "$os" == "linux" ]]; then
  suffix="-cpu"
elif [[ "$FLAVOR" == "mlx" ]]; then
  suffix="-mlx"
else
  suffix=""
fi
OUT="${DEST_DIR:-$ROOT/lib/${os}-${arch}${suffix}}"
SRC="$ROOT/build/vllm.cpp"
BUILD="$ROOT/build/${os}-${arch}-${FLAVOR}"

mkdir -p "$ROOT/build"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch --depth 1 origin "$REF"
  git -C "$SRC" checkout --force FETCH_HEAD
else
  rm -rf "$SRC"
  git clone --depth 1 --branch "$REF" "$SRC_URL" "$SRC" \
    || { git clone --depth 1 "$SRC_URL" "$SRC"
         git -C "$SRC" fetch --depth 1 origin "$REF"
         git -C "$SRC" checkout --force FETCH_HEAD; }
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
    if ! command -v nvcc >/dev/null 2>&1; then
      echo "CUDA flavor requires nvcc on PATH (nvidia/cuda:*-devel or a local toolkit)." >&2
      exit 1
    fi
    archs="${VLLM_CPP_CUDA_ARCHITECTURES:-80;86;89;90a}"
    cmake_args+=(
      -DVLLM_CPP_CUDA=ON
      -DVLLM_CPP_CUTLASS_FETCH=ON
      -DVLLM_CPP_CUDA_ARCHITECTURES="${archs}"
      -DCMAKE_CUDA_RUNTIME_LIBRARY=Shared
    )
    echo "==> nvcc $(nvcc --version | tail -1) archs=${archs}"
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
libs=()
while IFS= read -r -d '' f; do
  libs+=("$f")
done < <(find "$BUILD" \( -name 'libvllm.so*' -o -name 'libvllm*.dylib' -o -name 'vllm.dll' -o -name 'libvllm.dll' \) -print0 2>/dev/null || true)
if ((${#libs[@]} == 0)); then
  echo "libvllm shared library not found under $BUILD" >&2
  find "$BUILD" -name '*vllm*' | head -50 >&2 || true
  exit 1
fi
cp -a "${libs[@]}" "$OUT/"
if [[ "$os" == "linux" && ! -e "$OUT/libvllm.so" ]]; then
  first="$(ls -1 "$OUT"/libvllm.so* | head -1)"
  ln -sfn "$(basename "$first")" "$OUT/libvllm.so"
fi

if [[ "$FLAVOR" == "cuda" ]]; then
  chmod +x "$ROOT/scripts/stage-cuda-runtime.sh"
  "$ROOT/scripts/stage-cuda-runtime.sh" "$OUT"
fi

echo "staged:" && ls -la "$OUT"
