(in-package #:vllm-cpp)

;;; Layout matches include/vllm.h ABI v30 (LP64 / Windows x64).
(defconstant +vllm-abi-version+ 30)

(defcenum vllm-status
  (:ok 0)
  (:invalid-argument 1)
  (:model-load 2)
  (:runtime 3)
  (:unknown 4))

(defcstruct vllm-model-params
  ;; Field order and types follow include/vllm.h (VLLM_ABI_VERSION 30).
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
  (disable-sliding-window :int32)
  (device :int32)
  (gpu-memory-utilization :double)
  (kv-cache-memory-bytes :int64)
  (language-model-only :int32)
  (limit-mm-per-prompt :pointer)
  (mmproj-path :pointer)
  (kv-cache-dtype :pointer))

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

(defvar *vllm-loaded* nil)

(defun load-vllm ()
  "Load libvllm (and, on linux/amd64, its CUDA runtime). Idempotent.
ASDF load already ran the :native-library components (vllm-cpp.asd); this
retries the missing ones, e.g. when VLLM_CPP_NATIVE was set after load, and
signals VLLM-NOT-LOADED while libvllm is still absent. A library built for
another C ABI than +VLLM-ABI-VERSION+ signals VLLM-ABI-MISMATCH, with a
CONTINUE restart that uses it anyway."
  (unless *vllm-loaded*
    (dolist (c (asdf:component-children (asdf:find-system "vllm-cpp")))
      (when (typep c 'asdf-native:native-library)
        (handler-bind ((asdf-native:native-library-missing #'muffle-warning))
          (asdf-native:load-native-library c))))
    (unless (asdf-native:library-loaded-path "vllm-cpp" "vllm")
      (error 'vllm-not-loaded
             :message "libvllm not found (VLLM_CPP_NATIVE, native/, lib/<os>-<arch>/)"))
    (let ((abi (%vllm-abi-version)))
      (unless (= abi +vllm-abi-version+)
        (cerror "Use this libvllm anyway." 'vllm-abi-mismatch
                :library-abi abi :header-abi +vllm-abi-version+)))
    (setf *vllm-loaded* t))
  t)

(defun vllm-available-p ()
  (or *vllm-loaded*
      (handler-case (progn (load-vllm) t)
        (vllm-error () nil))))

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
