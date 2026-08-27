# CMAKE_PROJECT_INCLUDE hook. Upstream force-links the static `vllm` archive on
# Apple (-force_load) and UNIX (--whole-archive) so C ABI + registrars survive
# the linker. WIN32 has neither; without /WHOLEARCHIVE, vllm_shared is an empty
# stub DLL. Drop this file when mudler/vllm.cpp grows an MSVC branch.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL vllm_cpp_msvc_wholearchive)
function(vllm_cpp_msvc_wholearchive)
  if(MSVC AND TARGET vllm_shared AND TARGET vllm)
    target_link_options(vllm_shared PRIVATE "/WHOLEARCHIVE:$<TARGET_FILE:vllm>")
  endif()
endfunction()
