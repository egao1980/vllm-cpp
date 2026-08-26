# vllm-cpp

CFFI + native overlays for [`mudler/vllm.cpp`](https://github.com/mudler/vllm.cpp) (`libvllm`, C ABI `VLLM_ABI_VERSION` 23). Not the LLM protocol.

| Overlay | Build | Default device |
|---------|-------|----------------|
| `linux/amd64` | **CUDA** (`-DVLLM_CPP_CUDA=ON`, archs `80;86;89;90a`) | `:cuda` |
| `linux/arm64` | CPU | `:auto` |
| `darwin/arm64` | Metal `AUTO` | `:auto` |
| `windows/amd64` | CPU | `:auto` |

`arrange-native-artifacts` keys **os-arch only**, so the published linux/amd64 overlay **is** the CUDA build. CPU linux is local-only (`VLLM_CPP_FLAVOR=cpu` → `lib/linux-amd64-cpu/`). MLX is local-only (`VLLM_CPP_FLAVOR=mlx` → `lib/darwin-arm64-mlx/`). No second OCI platform, no `:release "cuda"`.

User-mode CUDA runtime (`libcudart` / `libcublas` / `libcublasLt`) is staged next to `libvllm` with `RPATH=$ORIGIN`. The NVIDIA **driver** (`libcuda`) is never shipped — the host must provide it. No `LD_LIBRARY_PATH`.

`:device :cuda` fails if the loaded `libvllm` was built without CUDA (ABI v14, no silent CPU fallback). `default-device` is `:cuda` on linux/amd64 unless `VLLM_CPP_FLAVOR=cpu` or `VLLM_DEVICE` overrides.

```lisp
(asdf:load-system "vllm-cpp")
(vllm-cpp:vllm-available-p)   ; NIL until libvllm is on the overlay / VLLM_CPP_NATIVE
(vllm-cpp:default-device)     ; :cuda on linux/amd64, :auto elsewhere
(let ((e (vllm-cpp:load-engine :model-path "/models/qwen")))
  (unwind-protect
       (vllm-cpp:complete e "ping" :max-tokens 32 :temperature 0)
    (vllm-cpp:free-engine e)))
```

Chat is engine-side (`vllm_chat` — OpenAI `/v1/chat/completions` JSON in/out).
llm-protocol lives in [`llm-protocol-vllm-cpp`](https://github.com/egao1980/llm-protocol-vllm-cpp).

Build: `./scripts/build-vllm.sh` (`VLLM_CPP_FLAVOR=cuda|cpu|mlx`, `VLLM_CPP_REF`, `MLX_ROOT`, `VLLM_CPP_CUDA_ARCHITECTURES`). Linux default flavor is `cuda` and requires `nvcc`.

## License

Lisp / this repo: MIT. Vendored `include/vllm.h` + `libvllm`: Apache-2.0 ([NOTICE](NOTICE)).
