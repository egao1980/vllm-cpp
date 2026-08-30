(in-package #:vllm-cpp)

;;; Layout matches include/vllm.h ABI v23 (LP64 / Windows x64).
(defconstant +vllm-abi-version+ 23)

(defcenum vllm-status
  (:ok 0)
  (:invalid-argument 1)
  (:model-load 2)
  (:runtime 3)
  (:unknown 4))

(defcstruct vllm-model-params
  (model-path :pointer)
  (tokenizer-config-path :pointer)
  (block-size :int32)
  (num-blocks :int32)
  (max-model-len :int32)
  (max-num-seqs :int32)
  (tool-parser :pointer)
  (reasoning-parser :pointer)
  (speculative-config :pointer)
  (enable-prefix-caching :int32)
  (max-num-batched-tokens :int32)
  (scheduling-policy :pointer)
  (kv-transfer-config :pointer)
  (offload-config :pointer)
  (enable-jump-forward :int32)
  (device :int32)
  (gpu-memory-utilization :double)
  (kv-cache-memory-bytes :int64)
  (language-model-only :int32)
  (limit-mm-per-prompt :pointer)
  (mmproj-path :pointer))

(defcstruct vllm-sampling-params
  (temperature :float)
  (top-p :float)
  (top-k :int32)
  (min-p :float)
  (max-tokens :int32)
  (seed :uint64)
  (has-seed :int32)
  (presence-penalty :float)
  (frequency-penalty :float)
  (repetition-penalty :float)
  (min-tokens :int32)
  (ignore-eos :int32)
  (stop :pointer)
  (n-stop :int32)
  (structured-json :pointer)
  (structured-regex :pointer)
  (structured-choice :pointer)
  (n-structured-choice :int32)
  (structured-grammar :pointer)
  (structured-json-object :int32)
  (logits-processor :pointer)
  (logits-processor-user-data :pointer))

(defcstruct vllm-completion
  (text :pointer)
  (finish-reason :pointer)
  (prompt-tokens :int32)
  (completion-tokens :int32))

(defcstruct vllm-embedding-result
  (values :pointer)
  (n-embeddings :int32)
  (dim :int32)
  (prompt-tokens :int32))

(define-foreign-library libvllm
  (:darwin (:or "libvllm.dylib" "libvllm.0.dylib"))
  (:unix (:or "libvllm.so" "libvllm.so.0"))
  (:windows (:or "vllm.dll" "libvllm.dll"))
  (t (:default "libvllm")))

(defun %host-os ()
  #+windows "windows"
  #+darwin "darwin"
  #+linux "linux"
  #-(or windows darwin linux) "unknown")

(defun %host-arch ()
  #+(or x86-64 x64) "amd64"
  #+(or arm64 aarch64) "arm64"
  #-(or x86-64 x64 arm64 aarch64) "unknown")

(defun %flavor ()
  (let ((v (uiop:getenv "VLLM_CPP_FLAVOR")))
    (when (and v (plusp (length v)))
      (string-downcase v))))

(defun %native-search-dirs ()
  "Overlay native/, lib/<os>-<arch>[-flavor]/. No LD_LIBRARY_PATH."
  (let ((dirs '())
        (flavor (%flavor)))
    (dolist (var '("VLLM_CPP_NATIVE" "LLM_PROTOCOL_VLLM_NATIVE"))
      (let ((v (uiop:getenv var)))
        (when (and v (plusp (length v)))
          (push v dirs))))
    (ignore-errors
      (let* ((sys (asdf:find-system :vllm-cpp nil))
             (root (when sys (asdf:system-source-directory sys))))
        (when root
          (push (namestring (merge-pathnames "native/" root)) dirs)
          (let ((base (format nil "lib/~A-~A" (%host-os) (%host-arch))))
            (when flavor
              (push (namestring (merge-pathnames (format nil "~A-~A/" base flavor) root))
                    dirs))
            (push (namestring (merge-pathnames (format nil "~A/" base) root)) dirs)))))
    (nreverse dirs)))

(defun %lib-candidates ()
  #+windows '("vllm.dll" "libvllm.dll")
  #+darwin '("libvllm.dylib" "libvllm.0.dylib")
  #+(and unix (not darwin)) '("libvllm.so" "libvllm.so.0")
  #-(or windows darwin unix) '("libvllm.so"))

(defun %find-named (dir names)
  (dolist (name names)
    (let ((p (merge-pathnames name (uiop:ensure-directory-pathname dir))))
      (when (probe-file p)
        (return (namestring (truename p)))))))

(defun %find-lib (dir)
  (%find-named dir (%lib-candidates)))

(defun %cuda-runtime-names (which)
  (ecase which
    (:cudart '("libcudart.so.12" "libcudart.so.13" "libcudart.so"))
    (:cublaslt '("libcublasLt.so.12" "libcublasLt.so.13" "libcublasLt.so"))
    (:cublas '("libcublas.so.12" "libcublas.so.13" "libcublas.so"))))

(defun %preload-cuda-runtime (dir)
  "Absolute-preload CUDA user-mode deps before libvllm. Never libcuda (driver)."
  (declare (ignorable dir))
  #+(and unix (not darwin))
  (dolist (which '(:cudart :cublaslt :cublas))
    (let ((abs (%find-named dir (%cuda-runtime-names which))))
      (when abs
        (handler-case (load-foreign-library abs)
          (error (e)
            (warn "vllm-cpp: failed to preload ~a (~a)" abs e))))))
  t)

(defvar *vllm-loaded* nil)

(defun load-vllm ()
  "Load libvllm. Idempotent. Signals VLLM-NOT-LOADED if nothing is found."
  (unless *vllm-loaded*
    (let ((preloaded nil))
      (dolist (dir (%native-search-dirs))
        (when (and dir (uiop:directory-exists-p dir))
          (pushnew dir cffi:*foreign-library-directories* :test #'equal)
          (unless preloaded
            (let ((abs (%find-lib dir)))
              (when abs
                (%preload-cuda-runtime dir)
                (load-foreign-library abs)
                (setf preloaded t))))))
      (unless preloaded
        (handler-case (load-foreign-library 'libvllm)
          (error (e)
            (error 'vllm-not-loaded
                   :message (princ-to-string e))))))
    (setf *vllm-loaded* t)
    (let ((abi (ignore-errors (%vllm-abi-version))))
      (when (and abi (/= abi +vllm-abi-version+))
        (warn "libvllm ABI ~a != pinned header ~a" abi +vllm-abi-version+))))
  t)

(defun vllm-available-p ()
  (or *vllm-loaded*
      (handler-case (progn (load-vllm) t)
        (vllm-not-loaded () nil)
        (error () nil))))

(defun ensure-vllm ()
  (or *vllm-loaded* (load-vllm)))

(defcfun ("vllm_engine_load" %engine-load) vllm-status
  (params (:pointer (:struct vllm-model-params)))
  (out :pointer))

(defcfun ("vllm_engine_free" %engine-free) :void
  (engine :pointer))

(defcfun ("vllm_complete" %complete) vllm-status
  (engine :pointer)
  (prompt :string)
  (params (:pointer (:struct vllm-sampling-params)))
  (out (:pointer (:struct vllm-completion))))

(defcfun ("vllm_complete_stream" %complete-stream) vllm-status
  (engine :pointer)
  (prompt :string)
  (params (:pointer (:struct vllm-sampling-params)))
  (cb :pointer)
  (user-data :pointer))

(defcfun ("vllm_chat" %chat) vllm-status
  (engine :pointer)
  (request-json :string)
  (out-response-json :pointer))

(defcfun ("vllm_chat_stream" %chat-stream) vllm-status
  (engine :pointer)
  (request-json :string)
  (cb :pointer)
  (user-data :pointer))

(defcfun ("vllm_string_free" %string-free) :void
  (s :pointer))

(defcfun ("vllm_completion_free" %completion-free) :void
  (out (:pointer (:struct vllm-completion))))

(defcfun ("vllm_embed" %embed) vllm-status
  (engine :pointer)
  (texts :pointer)
  (n-texts :int32)
  (out (:pointer (:struct vllm-embedding-result))))

(defcfun ("vllm_embedding_result_free" %embedding-result-free) :void
  (out (:pointer (:struct vllm-embedding-result))))

(defcfun ("vllm_last_error" %last-error) :string)

(defcfun ("vllm_version" %vllm-version) :string)

(defcfun ("vllm_abi_version" %vllm-abi-version) :int32)

(defun vllm-last-error ()
  (ensure-vllm)
  (%last-error))

(defun vllm-version ()
  (ensure-vllm)
  (%vllm-version))

(defun vllm-abi-version ()
  (ensure-vllm)
  (%vllm-abi-version))

(defun %check (status op)
  (unless (eq status :ok)
    (error 'vllm-error
           :status status
           :message (format nil "~a: ~a" op (ignore-errors (%last-error)))))
  status)

;;; Soft auto-load: overlay consumers get the lib; CI without natives still loads.
(eval-when (:load-toplevel :execute)
  (handler-case (load-vllm)
    (error (e)
      (warn "vllm-cpp: libvllm not loaded (~a). GENERATE needs an overlay or VLLM_CPP_NATIVE."
            e))))
