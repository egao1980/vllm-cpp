# vllm-cpp

CFFI + native overlays for [`mudler/vllm.cpp`](https://github.com/mudler/vllm.cpp) (`libvllm`, C ABI `VLLM_ABI_VERSION` 23). Not the LLM protocol.

| Overlay | Build | Device (`vllm_model_params.device`) |
|---------|-------|--------------------------------------|
| `linux/{amd64,arm64}` | CPU (`-DVLLM_CPP_CUDA=OFF`) | `:auto` / `:cpu` |
| `linux/amd64` `:release "cuda"` | `-DVLLM_CPP_CUDA=ON` | `:cuda` (no silent CPU fallback) |
| `darwin/arm64` | Metal `AUTO` | `:auto` |
| `darwin/arm64` `:release "mlx"` | `-DVLLM_CPP_MLX=ON` | `:auto` (MLX GEMM on Metal prefill) |
| `windows/amd64` | CPU | `:auto` / `:cpu` |

`VLLM_CPP_FLAVOR=cpu|cuda|mlx` picks `lib/<os>-<arch>[-flavor]/`. No `LD_LIBRARY_PATH`.

```lisp
(asdf:load-system "vllm-cpp")
(vllm-cpp:vllm-available-p)   ; NIL until libvllm is on the overlay / VLLM_CPP_NATIVE
(let ((e (vllm-cpp:load-engine :model-path "/models/qwen" :device :auto)))
  (unwind-protect
       (vllm-cpp:complete e "ping" :max-tokens 32 :temperature 0)
    (vllm-cpp:free-engine e)))
```

Chat is engine-side (`vllm_chat` — OpenAI `/v1/chat/completions` JSON in/out).
llm-protocol lives in [`llm-protocol-vllm-cpp`](https://github.com/egao1980/llm-protocol-vllm-cpp).

Build: `./scripts/build-vllm.sh` (`VLLM_CPP_FLAVOR`, `VLLM_CPP_REF`, `MLX_ROOT`, `VLLM_CPP_CUDA_ARCHITECTURES`).

## License

Lisp / this repo: MIT. Vendored `include/vllm.h` + `libvllm`: Apache-2.0 ([NOTICE](NOTICE)).
