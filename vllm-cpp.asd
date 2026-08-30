(defsystem "vllm-cpp"
  :version "0.1.2"
  :description "CFFI + native overlays for mudler/vllm.cpp (libvllm; linux/amd64 is CUDA)"
  :author "egao1980"
  :license "MIT"
  :depends-on ("cffi" "trivial-garbage")
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "ffi")
               (:file "api"))
  :in-order-to ((test-op (test-op "vllm-cpp/tests")))
  :properties
  (:cl-repo
   (:cffi-libraries ("libvllm")
    :provides ("vllm-cpp")
    :overlays
    ((:platform (:os "linux" :arch "amd64")
      :layers ((:role "native-library"
                :files (("lib/linux-amd64/libvllm.so" . "libvllm.so")
                        ("lib/linux-amd64/libcudart.so.12" . "libcudart.so.12")
                        ("lib/linux-amd64/libcublas.so.12" . "libcublas.so.12")
                        ("lib/linux-amd64/libcublasLt.so.12" . "libcublasLt.so.12")))))
     (:platform (:os "linux" :arch "arm64")
      :layers ((:role "native-library"
                :files (("lib/linux-arm64/libvllm.so" . "libvllm.so")))))
     (:platform (:os "darwin" :arch "arm64")
      :layers ((:role "native-library"
                :files (("lib/darwin-arm64/libvllm.dylib" . "libvllm.dylib")))))
     (:platform (:os "windows" :arch "amd64")
      :layers ((:role "native-library"
                :files (("lib/windows-amd64/vllm.dll" . "vllm.dll")))))))))

(defsystem "vllm-cpp/tests"
  :depends-on ("vllm-cpp" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "api-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
