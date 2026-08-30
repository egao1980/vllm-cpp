(in-package #:vllm-cpp/tests)

(deftest abi-pin
  (ok (= 23 vllm-cpp:+vllm-abi-version+)))

(deftest device-codes
  (dolist (pair '((:auto 0) (:cpu 1) (:cuda 2) ("cuda" 2)))
    (ok (= (second pair) (vllm-cpp:device-code (first pair))))))

(deftest device-keyword-roundtrip
  (ok (eq :auto (vllm-cpp:device-keyword 0)))
  (ok (eq :cpu (vllm-cpp:device-keyword 1)))
  (ok (eq :cuda (vllm-cpp:device-keyword 2))))

(deftest default-device-matrix
  (dolist (row '(("linux" "amd64" nil nil :cuda)
                 ("linux" "amd64" "cpu" nil :auto)
                 ("linux" "amd64" "cuda" nil :cuda)
                 ("linux" "arm64" nil nil :auto)
                 ("linux" "arm64" nil "0.1.0+cuda" :cuda)
                 ("darwin" "arm64" nil nil :auto)
                 ("darwin" "arm64" nil "0.1.0+cuda" :cuda)
                 ("windows" "amd64" nil nil :auto)))
    (destructuring-bind (os arch flavor version expected) row
      (ok (eq expected (vllm-cpp::%default-device-for os arch flavor version))))))

(deftest default-device-env
  (let ((old-dev (or (uiop:getenv "VLLM_DEVICE") ""))
        (old-flav (or (uiop:getenv "VLLM_CPP_FLAVOR") "")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "VLLM_DEVICE") "cuda")
           (ok (eq :cuda (vllm-cpp:default-device)))
           (setf (uiop:getenv "VLLM_DEVICE") "cpu")
           (ok (eq :cpu (vllm-cpp:default-device)))
           (setf (uiop:getenv "VLLM_DEVICE") "")
           (setf (uiop:getenv "VLLM_CPP_FLAVOR") "cpu")
           (ok (eq :auto (vllm-cpp:default-device))))
      (setf (uiop:getenv "VLLM_DEVICE") old-dev)
      (setf (uiop:getenv "VLLM_CPP_FLAVOR") old-flav))))

(deftest default-device-returns-keyword
  (ok (member (vllm-cpp:default-device) '(:auto :cpu :cuda))))

(deftest available-p-does-not-crash
  (ok (member (vllm-cpp:vllm-available-p) '(t nil))))

(deftest load-engine-without-model
  (if (vllm-cpp:vllm-available-p)
      (ok (signals (vllm-cpp:load-engine :model-path nil)
                   'vllm-cpp:vllm-missing-model))
      (skip "libvllm not present")))

(deftest embed-rejects-non-engine
  (ok (signals (vllm-cpp:embed "not-an-engine" "hi")
               'vllm-cpp:vllm-error)))

(deftest live-embed
  (let ((path (or (uiop:getenv "VLLM_EMBED_MODEL_PATH")
                  (uiop:getenv "VLLM_MODEL_PATH"))))
    (cond
      ((not (vllm-cpp:vllm-available-p))
       (skip "libvllm not present"))
      ((or (null path) (zerop (length path)))
       (skip "set VLLM_EMBED_MODEL_PATH for a live embed"))
      (t
       (let ((e (vllm-cpp:load-engine :model-path path)))
         (unwind-protect
              (handler-case
                  (multiple-value-bind (vecs dim tokens)
                      (vllm-cpp:embed e "hello")
                    (ok (consp vecs))
                    (ok (plusp dim))
                    (ok (= dim (length (first vecs))))
                    (ok (integerp tokens)))
                (vllm-cpp:vllm-error (err)
                  (skip (format nil "not a pooling checkpoint: ~a" err))))
           (vllm-cpp:free-engine e)))))))

(deftest live-complete
  (let ((path (uiop:getenv "VLLM_MODEL_PATH")))
    (cond
      ((not (vllm-cpp:vllm-available-p))
       (skip "libvllm not present"))
      ((or (null path) (zerop (length path)))
       (skip "set VLLM_MODEL_PATH for a live complete"))
      (t
       (let ((e (vllm-cpp:load-engine :model-path path)))
         (unwind-protect
              (multiple-value-bind (text reason)
                  (vllm-cpp:complete e "Reply with pong." :temperature 0 :max-tokens 32)
                (ok (stringp text))
                (ok (plusp (length text)))
                (ok (or (null reason) (stringp reason))))
           (vllm-cpp:free-engine e)))))))
