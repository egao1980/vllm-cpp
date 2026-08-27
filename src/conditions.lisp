(in-package #:vllm-cpp)

(define-condition vllm-error (error)
  ((status :initarg :status :reader vllm-error-status :initform nil)
   (message :initarg :message :reader vllm-error-message :initform nil))
  (:report (lambda (c s)
             (format s "vllm-cpp error~@[ (~a)~]~@[: ~a~]"
                     (vllm-error-status c)
                     (vllm-error-message c)))))

(define-condition vllm-not-loaded (vllm-error) ()
  (:report (lambda (c s)
             (format s "libvllm is not loaded~@[: ~a~]" (vllm-error-message c)))))

(define-condition vllm-missing-model (vllm-error) ()
  (:report (lambda (c s)
             (format s "vllm model path missing~@[: ~a~]" (vllm-error-message c)))))
