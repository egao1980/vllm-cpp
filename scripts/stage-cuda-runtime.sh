#!/usr/bin/env bash
# Copy CUDA user-mode DT_NEEDED libs next to libvllm and set RPATH=$ORIGIN.
# Guarantees the CUDA 12 SONAMEs listed in vllm-cpp.asd.
# Never ships libcuda (the driver). No LD_LIBRARY_PATH.
set -euo pipefail

DEST="${1:?usage: stage-cuda-runtime.sh DEST_DIR}"
DEST="$(cd "$DEST" && pwd)"

shopt -s nullglob
vllms=("$DEST"/libvllm.so*)
if ((${#vllms[@]} == 0)); then
  echo "stage-cuda-runtime: no libvllm.so* in $DEST" >&2
  exit 1
fi

is_driver() {
  case "$(basename "$1")" in
    libcuda.so|libcuda.so.*) return 0 ;;
  esac
  return 1
}

is_system() {
  case "$(basename "$1")" in
    libc.so|libc.so.*|libm.so|libm.so.*|libdl.so|libdl.so.*|librt.so|librt.so.*) return 0 ;;
    libpthread.so|libpthread.so.*|libgcc_s.so|libgcc_s.so.*|libstdc++.so|libstdc++.so.*) return 0 ;;
    ld-linux*|ld64.so*|linux-vdso.so*) return 0 ;;
  esac
  return 1
}

copy_dep() {
  local src="$1"
  [[ -e "$src" ]] || return 0
  is_driver "$src" && return 0
  is_system "$src" && return 0
  local base dest
  base="$(basename "$src")"
  dest="$DEST/$base"
  if [[ -e "$dest" ]]; then
    return 0
  fi
  cp -a "$src" "$dest"
  # Follow a single symlink hop so both SONAME and real file land in DEST.
  if [[ -L "$src" ]]; then
    local real
    real="$(readlink -f "$src" || true)"
    if [[ -n "$real" && -e "$real" ]]; then
      local rbase
      rbase="$(basename "$real")"
      if [[ "$rbase" != "$base" && ! -e "$DEST/$rbase" ]]; then
        cp -a "$real" "$DEST/$rbase"
      fi
    fi
  fi
}

for lib in "${vllms[@]}"; do
  [[ -f "$lib" && ! -L "$lib" ]] || continue
  while read -r dep; do
    [[ -n "$dep" ]] || continue
    copy_dep "$dep"
  done < <(ldd "$lib" | awk '/=>/ { print $3 }')
done

# Drop the driver if ldd/copy ever let it through.
rm -f "$DEST"/libcuda.so "$DEST"/libcuda.so.*

cuda_lib_dirs=(
  /usr/local/cuda/lib64
  /usr/local/cuda/lib
  /usr/lib/x86_64-linux-gnu
)

copy_named() {
  local name="$1"
  if [[ -e "$DEST/$name" ]]; then
    return 0
  fi
  local d hit
  for d in "${cuda_lib_dirs[@]}"; do
    if [[ -e "$d/$name" ]]; then
      copy_dep "$d/$name"
      return 0
    fi
    hit="$(ls -1 "$d/$name"* 2>/dev/null | head -1 || true)"
    if [[ -n "$hit" ]]; then
      copy_dep "$hit"
      return 0
    fi
  done
  return 1
}

ensure_soname() {
  local stem="$1"
  local want="${stem}.so.12"
  if [[ -e "$DEST/$want" ]]; then
    return 0
  fi
  local f
  for f in "$DEST/${stem}.so."*; do
    [[ -e "$f" ]] || continue
    ln -sfn "$(basename "$f")" "$DEST/$want"
    return 0
  done
  return 1
}

for stem in libcudart libcublasLt libcublas; do
  copy_named "${stem}.so.12" || true
  ensure_soname "$stem" || true
done

missing=0
for req in libcudart.so.12 libcublasLt.so.12 libcublas.so.12; do
  if [[ ! -e "$DEST/$req" ]]; then
    echo "stage-cuda-runtime: required $req missing in $DEST" >&2
    missing=1
  fi
done
if ((missing)); then
  ls -la "$DEST" >&2
  exit 1
fi

if command -v patchelf >/dev/null 2>&1; then
  for f in "$DEST"/*.so "$DEST"/*.so.*; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    is_driver "$f" && continue
    patchelf --set-rpath '$ORIGIN' "$f"
  done
else
  echo "stage-cuda-runtime: patchelf not found; RPATH not set (install patchelf)" >&2
fi

if [[ ! -e "$DEST/libvllm.so" ]]; then
  first="$(ls -1 "$DEST"/libvllm.so* | head -1)"
  ln -sfn "$(basename "$first")" "$DEST/libvllm.so"
fi

echo "CUDA runtime staged in $DEST:"
ls -la "$DEST"
