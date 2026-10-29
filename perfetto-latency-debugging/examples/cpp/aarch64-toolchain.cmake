# Example only. Set actual compatible compilers on the cmake command line.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
if(NOT DEFINED CMAKE_CXX_COMPILER)
  message(FATAL_ERROR "Provide -DCMAKE_CXX_COMPILER=/absolute/path/to/aarch64-...-g++")
endif()
