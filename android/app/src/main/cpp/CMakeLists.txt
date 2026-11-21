cmake_minimum_required(VERSION 3.22.1)
project(resonate_dsp LANGUAGES C CXX)

# Resonate owns playback through Media3. Build the upstream DSP processor as a
# shared library, but do not select its standalone AAudio output backend.
set(DSP_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(DSP_BUILD_STATIC OFF CACHE BOOL "" FORCE)
set(DSP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DSP_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(DSP_BACKEND_AAUDIO OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/DSP-ENGINE dsp_engine_upstream)

find_library(log-lib log)

add_library(dsp_jni SHARED dsp_engine_jni.cpp)
target_include_directories(dsp_jni PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/DSP-ENGINE/include
)
target_compile_features(dsp_jni PRIVATE cxx_std_17)
target_compile_options(dsp_jni PRIVATE -O2 -fPIC -fno-exceptions -fno-rtti)
target_link_libraries(dsp_jni PRIVATE dsp_engine ${log-lib})
