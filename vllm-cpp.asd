(defsystem "vllm-cpp"
  :version "0.2.1"
  :description "CFFI + native overlays for mudler/vllm.cpp (libvllm; linux/amd64 is CUDA)"
  :author "egao1980"
  :license "MIT"
  :defsystem-depends-on ("asdf-native")
  :depends-on ("cffi" "trivial-garbage")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               ;; $VLLM_CPP_NATIVE, $LLM_PROTOCOL_VLLM_NATIVE, lib/<os>-<arch>-$VLLM_CPP_FLAVOR/,
               ;; native/ (overlay), lib/<os>-<arch>/ (checkout), else (libvllm) the system.
               ;; All optional: a checkout without natives still loads (VLLM-AVAILABLE-P is NIL).
               ;; CUDA user-mode runtime first (linux/amd64 overlay). Never libcuda (driver).
               (:native-library "cudart" :versions ("12") :env "VLLM_CPP_NATIVE"
                :directories ("{env:LLM_PROTOCOL_VLLM_NATIVE}/" "lib/{pair}-{env:VLLM_CPP_FLAVOR}/")
                :optional t)
               (:native-library "cublasLt" :versions ("12") :env "VLLM_CPP_NATIVE"
                :directories ("{env:LLM_PROTOCOL_VLLM_NATIVE}/" "lib/{pair}-{env:VLLM_CPP_FLAVOR}/")
                :optional t)
               (:native-library "cublas" :versions ("12") :env "VLLM_CPP_NATIVE"
                :directories ("{env:LLM_PROTOCOL_VLLM_NATIVE}/" "lib/{pair}-{env:VLLM_CPP_FLAVOR}/")
                :optional t)
               (:native-library "vllm" :versions ("0") :env "VLLM_CPP_NATIVE"
                :directories ("{env:LLM_PROTOCOL_VLLM_NATIVE}/" "lib/{pair}-{env:VLLM_CPP_FLAVOR}/")
                :system t :optional t)
               (:file "ffi")
               (:file "api"))
  :in-order-to ((test-op (test-op "vllm-cpp/tests")))
  ;; Overlays: lib/<os>-<arch>/ per platform, from the :native-library components.
  :properties (:cl-repo (:provides ("vllm-cpp"))))

(defsystem "vllm-cpp/tests"
  :depends-on ("vllm-cpp" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "api-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
