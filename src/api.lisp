(in-package #:vllm-cpp)

(defun device-code (device)
  (etypecase device
    ((eql :auto) 0)
    ((eql :cpu) 1)
    ((eql :cuda) 2)
    ((integer 0 2) device)
    (string (device-code (intern (string-upcase device) :keyword)))))

(defun device-keyword (code)
  (ecase code
    (0 :auto)
    (1 :cpu)
    (2 :cuda)))

(defun %default-device-for (os arch flavor &optional version)
  "linux/amd64 published overlay is CUDA. CPU flavor stays :auto.
   Other hosts become :cuda only when libvllm reports +cuda."
  (cond
    ((equal flavor "cpu") :auto)
    ((and (string-equal os "linux") (string-equal arch "amd64")) :cuda)
    ((and version (search "+cuda" version :test #'char-equal)) :cuda)
    (t :auto)))

(defun default-device ()
  "Device when :device / VLLM_DEVICE are omitted.
   linux/amd64 → :cuda (the published overlay). CPU flavor and other hosts → :auto
   unless the loaded libvllm version string has +cuda. Explicit :cuda never
   falls back to CPU (ABI v14)."
  (let ((env (%env "VLLM_DEVICE")))
    (when env
      (return-from default-device (intern (string-upcase env) :keyword))))
  (%default-device-for (%host-os) (%host-arch) (%flavor)
                       (and *vllm-loaded* (ignore-errors (%vllm-version)))))

(defun %env (name)
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defclass vllm-engine ()
  ((pointer :initarg :pointer :accessor engine-pointer)
   (model-path :initarg :model-path :accessor engine-model-path)
   (device :initarg :device :accessor engine-device :initform :auto)
   (freed :initform nil :accessor engine-freed-p)))

(defun vllm-engine-p (x)
  (typep x 'vllm-engine))

(defun free-engine (engine)
  (when (and engine (not (engine-freed-p engine)))
    (let ((p (engine-pointer engine)))
      (when (and p (not (null-pointer-p p)))
        (%engine-free p)))
    (setf (engine-pointer engine) (null-pointer)
          (engine-freed-p engine) t))
  engine)

(defun %finalize-engine (engine)
  (ignore-errors (free-engine engine)))

(defun load-engine (&key model-path device tokenizer-config-path
                      tool-parser reasoning-parser speculative-config
                      scheduling-policy max-model-len max-num-seqs
                      gpu-memory-utilization)
  "Load a text engine. DEVICE is :auto / :cpu / :cuda (ABI v14).
   Omitted DEVICE uses DEFAULT-DEVICE (CUDA on the published linux/amd64 overlay)."
  (ensure-vllm)
  (let ((path (or model-path (%env "VLLM_MODEL_PATH") (%env "VLLM_CPP_MODEL")))
        (resolved (or device (default-device))))
    (unless (and path (plusp (length path)))
      (error 'vllm-missing-model
             :message "pass :model-path or set VLLM_MODEL_PATH"))
    (with-foreign-string (c-path path)
      (with-foreign-object (params '(:struct vllm-model-params))
        (dotimes (i (foreign-type-size '(:struct vllm-model-params)))
          (setf (mem-aref params :uint8 i) 0))
        (setf (foreign-slot-value params '(:struct vllm-model-params) 'model-path) c-path
              (foreign-slot-value params '(:struct vllm-model-params) 'device)
              (device-code resolved))
        (when max-model-len
          (setf (foreign-slot-value params '(:struct vllm-model-params) 'max-model-len)
                max-model-len))
        (when max-num-seqs
          (setf (foreign-slot-value params '(:struct vllm-model-params) 'max-num-seqs)
                max-num-seqs))
        (when gpu-memory-utilization
          (setf (foreign-slot-value params '(:struct vllm-model-params) 'gpu-memory-utilization)
                (float gpu-memory-utilization 1d0)))
        (with-foreign-strings ((c-tok (or tokenizer-config-path ""))
                               (c-tool (or tool-parser ""))
                               (c-reason (or reasoning-parser ""))
                               (c-spec (or speculative-config ""))
                               (c-sched (or scheduling-policy "")))
          (when tokenizer-config-path
            (setf (foreign-slot-value params '(:struct vllm-model-params) 'tokenizer-config-path)
                  c-tok))
          (when tool-parser
            (setf (foreign-slot-value params '(:struct vllm-model-params) 'tool-parser)
                  c-tool))
          (when reasoning-parser
            (setf (foreign-slot-value params '(:struct vllm-model-params) 'reasoning-parser)
                  c-reason))
          (when speculative-config
            (setf (foreign-slot-value params '(:struct vllm-model-params) 'speculative-config)
                  c-spec))
          (when scheduling-policy
            (setf (foreign-slot-value params '(:struct vllm-model-params) 'scheduling-policy)
                  c-sched))
          (with-foreign-object (out :pointer)
            (setf (mem-ref out :pointer) (null-pointer))
            (%check (%engine-load params out) "vllm_engine_load")
            (let* ((ptr (mem-ref out :pointer))
                   (engine (make-instance 'vllm-engine
                                          :pointer ptr
                                          :model-path path
                                          :device (device-keyword
                                                   (device-code resolved)))))
              (tg:finalize engine (lambda () (%finalize-engine engine)))
              engine)))))))

(defun ensure-engine (engine)
  (cond
    ((vllm-engine-p engine)
     (when (or (engine-freed-p engine)
               (null-pointer-p (engine-pointer engine)))
       (error 'vllm-error :message "engine already freed"))
     engine)
    (t (error 'vllm-error :message (format nil "not a vllm-engine: ~s" engine)))))

(defun %as-string-list (x)
  (cond
    ((null x) nil)
    ((stringp x) (list x))
    ((or (listp x) (vectorp x)) (map 'list #'princ-to-string x))
    (t (list (princ-to-string x)))))

(defun %fill-sampling (ptr &key temperature top-p top-k min-p max-tokens seed
                       presence-penalty frequency-penalty repetition-penalty
                       min-tokens ignore-eos stop
                       structured-json structured-regex structured-choice
                       structured-grammar structured-json-object)
  ;; Zero-init is not valid (repetition_penalty must be > 0). Match upstream defaults.
  (dotimes (i (foreign-type-size '(:struct vllm-sampling-params)))
    (setf (mem-aref ptr :uint8 i) 0))
  (setf (foreign-slot-value ptr '(:struct vllm-sampling-params) 'temperature) 1f0
        (foreign-slot-value ptr '(:struct vllm-sampling-params) 'top-p) 1f0
        (foreign-slot-value ptr '(:struct vllm-sampling-params) 'repetition-penalty) 1f0)
  (flet ((set-slot (name value)
           (when value
             (setf (foreign-slot-value ptr '(:struct vllm-sampling-params) name) value))))
    (set-slot 'temperature (and temperature (float temperature 1f0)))
    (set-slot 'top-p (and top-p (float top-p 1f0)))
    (set-slot 'top-k top-k)
    (set-slot 'min-p (and min-p (float min-p 1f0)))
    (set-slot 'max-tokens max-tokens)
    (when seed
      (set-slot 'seed seed)
      (set-slot 'has-seed 1))
    (set-slot 'presence-penalty (and presence-penalty (float presence-penalty 1f0)))
    (set-slot 'frequency-penalty (and frequency-penalty (float frequency-penalty 1f0)))
    (set-slot 'repetition-penalty (and repetition-penalty (float repetition-penalty 1f0)))
    (set-slot 'min-tokens min-tokens)
    (when ignore-eos
      (set-slot 'ignore-eos (if ignore-eos 1 0)))
    (set-slot 'structured-json-object (and structured-json-object 1)))
  (values stop structured-json structured-regex structured-choice structured-grammar))

(defmacro %with-c-strings (bindings &body body)
  (if (null bindings)
      `(progn ,@body)
      (destructuring-bind (var val) (first bindings)
        `(with-foreign-string (,var (or ,val ""))
           (%with-c-strings ,(rest bindings) ,@body)))))

(defun %with-sampling (args fn)
  (destructuring-bind (&key temperature top-p top-k min-p max-tokens seed
                         presence-penalty frequency-penalty repetition-penalty
                         min-tokens ignore-eos stop
                         structured-json structured-regex structured-choice
                         structured-grammar structured-json-object)
      args
    (let ((stops (%as-string-list stop))
          (choices (%as-string-list structured-choice)))
      (with-foreign-object (params '(:struct vllm-sampling-params))
        (%fill-sampling params
                        :temperature temperature :top-p top-p :top-k top-k
                        :min-p min-p :max-tokens max-tokens :seed seed
                        :presence-penalty presence-penalty
                        :frequency-penalty frequency-penalty
                        :repetition-penalty repetition-penalty
                        :min-tokens min-tokens :ignore-eos ignore-eos
                        :structured-json-object structured-json-object)
        (%with-c-strings ((c-json structured-json)
                          (c-regex structured-regex)
                          (c-grammar structured-grammar))
          (when structured-json
            (setf (foreign-slot-value params '(:struct vllm-sampling-params) 'structured-json)
                  c-json))
          (when structured-regex
            (setf (foreign-slot-value params '(:struct vllm-sampling-params) 'structured-regex)
                  c-regex))
          (when structured-grammar
            (setf (foreign-slot-value params '(:struct vllm-sampling-params) 'structured-grammar)
                  c-grammar))
          (with-foreign-objects ((stop-arr :pointer (max 1 (length stops)))
                                 (choice-arr :pointer (max 1 (length choices))))
            (let ((owned '()))
              (unwind-protect
                   (progn
                     (loop for s in stops for i from 0
                           for p = (foreign-string-alloc s)
                           do (push p owned)
                              (setf (mem-aref stop-arr :pointer i) p))
                     (when stops
                       (setf (foreign-slot-value params '(:struct vllm-sampling-params) 'stop)
                             stop-arr
                             (foreign-slot-value params '(:struct vllm-sampling-params) 'n-stop)
                             (length stops)))
                     (loop for s in choices for i from 0
                           for p = (foreign-string-alloc s)
                           do (push p owned)
                              (setf (mem-aref choice-arr :pointer i) p))
                     (when choices
                       (setf (foreign-slot-value params '(:struct vllm-sampling-params)
                                                 'structured-choice)
                             choice-arr
                             (foreign-slot-value params '(:struct vllm-sampling-params)
                                                 'n-structured-choice)
                             (length choices)))
                     (funcall fn params))
                (mapc #'foreign-string-free owned)))))))))

(defun complete (engine prompt &rest sampling)
  "Blocking completion. Returns (values text finish-reason prompt-tokens completion-tokens)."
  (let ((e (ensure-engine engine)))
    (%with-sampling sampling
      (lambda (params)
        (with-foreign-object (out '(:struct vllm-completion))
          (dotimes (i (foreign-type-size '(:struct vllm-completion)))
            (setf (mem-aref out :uint8 i) 0))
          (%check (%complete (engine-pointer e) prompt params out) "vllm_complete")
          (unwind-protect
               (let ((text-ptr (foreign-slot-value out '(:struct vllm-completion) 'text))
                     (reason-ptr (foreign-slot-value out '(:struct vllm-completion) 'finish-reason)))
                 (values (if (or (null text-ptr) (null-pointer-p text-ptr))
                             ""
                             (foreign-string-to-lisp text-ptr))
                         (if (or (null reason-ptr) (null-pointer-p reason-ptr))
                             nil
                             (foreign-string-to-lisp reason-ptr))
                         (foreign-slot-value out '(:struct vllm-completion) 'prompt-tokens)
                         (foreign-slot-value out '(:struct vllm-completion) 'completion-tokens)))
            (%completion-free out)))))))

(defvar *stream-callback* nil)

(defcallback %token-callback :bool
    ((delta-text :string) (finished :boolean) (user-data :pointer))
  (declare (ignore user-data))
  (if *stream-callback*
      (let ((cont (funcall *stream-callback* (or delta-text "") finished)))
        (if (eq cont :stop) nil t))
      t))

(defun complete-stream (engine prompt on-delta &rest sampling)
  "Blocking stream. ON-DELTA is (lambda (delta-text finished-p)). Return :stop to abort."
  (let ((e (ensure-engine engine))
        (*stream-callback* on-delta))
    (%with-sampling sampling
      (lambda (params)
        (%check (%complete-stream (engine-pointer e) prompt params
                                  (callback %token-callback)
                                  (null-pointer))
                "vllm_complete_stream")))))

(defun chat (engine request-json)
  "Blocking OpenAI-style chat. REQUEST-JSON is a string. Returns the response JSON string."
  (check-type request-json string)
  (let ((e (ensure-engine engine)))
    (with-foreign-object (out :pointer)
      (setf (mem-ref out :pointer) (null-pointer))
      (%check (%chat (engine-pointer e) request-json out) "vllm_chat")
      (let ((ptr (mem-ref out :pointer)))
        (unwind-protect
             (if (or (null ptr) (null-pointer-p ptr))
                 "{}"
                 (foreign-string-to-lisp ptr))
          (unless (or (null ptr) (null-pointer-p ptr))
            (%string-free ptr)))))))

(defun embed (engine texts)
  "Blocking embed. TEXTS is a string or sequence of strings.
   → (values list-of-single-float-vectors dim prompt-tokens)."
  (let* ((e (ensure-engine engine))
         (list (cond
                 ((stringp texts) (list texts))
                 ((or (listp texts) (vectorp texts))
                  (map 'list (lambda (x)
                               (if (stringp x) x (princ-to-string x)))
                       texts))
                 (t (list (princ-to-string texts)))))
         (n (length list)))
    (when (zerop n)
      (error 'vllm-error :message "embed requires at least one text"))
    (with-foreign-objects ((arr :pointer n)
                           (out '(:struct vllm-embedding-result)))
      (dotimes (i (foreign-type-size '(:struct vllm-embedding-result)))
        (setf (mem-aref out :uint8 i) 0))
      (let ((owned '()))
        (unwind-protect
             (progn
               (loop for s in list for i from 0
                     for p = (foreign-string-alloc s)
                     do (push p owned)
                        (setf (mem-aref arr :pointer i) p))
               (%check (%embed (engine-pointer e) arr n out) "vllm_embed")
               (let* ((vals (foreign-slot-value out '(:struct vllm-embedding-result)
                                                'values))
                      (n-emb (foreign-slot-value out '(:struct vllm-embedding-result)
                                                 'n-embeddings))
                      (dim (foreign-slot-value out '(:struct vllm-embedding-result)
                                               'dim))
                      (tokens (foreign-slot-value out '(:struct vllm-embedding-result)
                                                  'prompt-tokens))
                      (vecs (loop for i from 0 below n-emb
                                  collect
                                  (let ((v (make-array dim :element-type 'single-float)))
                                    (dotimes (j dim)
                                      (setf (aref v j)
                                            (mem-aref vals :float (+ (* i dim) j))))
                                    v))))
                 (values vecs dim tokens)))
          (ignore-errors (%embedding-result-free out))
          (mapc #'foreign-string-free owned))))))

(defun chat-stream (engine request-json on-delta)
  "Blocking streaming chat. ON-DELTA gets each OpenAI chunk JSON (or \"\" on finish)."
  (check-type request-json string)
  (let ((e (ensure-engine engine))
        (*stream-callback* on-delta))
    (%check (%chat-stream (engine-pointer e) request-json
                          (callback %token-callback)
                          (null-pointer))
            "vllm_chat_stream")))
