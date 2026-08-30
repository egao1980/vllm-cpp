(defpackage #:vllm-cpp
  (:use #:cl #:cffi)
  (:local-nicknames (#:tg #:trivial-garbage))
  (:nicknames #:stack-vllm)
  (:export #:+vllm-abi-version+
           #:vllm-error
           #:vllm-error-status
           #:vllm-error-message
           #:vllm-not-loaded
           #:vllm-missing-model

           #:libvllm
           #:load-vllm
           #:vllm-available-p
           #:vllm-version
           #:vllm-abi-version
           #:vllm-last-error

           #:device-code
           #:device-keyword
           #:default-device

           #:vllm-engine
           #:vllm-engine-p
           #:engine-pointer
           #:engine-model-path
           #:engine-device
           #:load-engine
           #:free-engine
           #:ensure-engine

           #:complete
           #:complete-stream
           #:chat
           #:chat-stream
           #:embed))

(in-package #:vllm-cpp)
