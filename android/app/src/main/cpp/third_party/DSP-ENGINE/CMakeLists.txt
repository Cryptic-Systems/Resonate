cmake_minimum_required(VERSION 3.16)

project(DSP_ENGINE
    VERSION 0.4.0
    DESCRIPTION "64-bit DSP processing engine with Direct Volume Control and parametric EQ"
    LANGUAGES C CXX
)

option(DSP_BUILD_SHARED     "Build shared library"                  ON)
option(DSP_BUILD_STATIC     "Build static library"                  ON)
option(DSP_BUILD_TESTS      "Build unit tests and benchmarks"       ON)
option(DSP_BUILD_EXAMPLES   "Build example apps"                    ON)
option(DSP_ENABLE_SIMD      "Enable SIMD (AVX2/NEON) optimizations" ON)
option(DSP_BIT_PERFECT      "Enable bit-perfect processing path"    ON)
option(DSP_USE_DOUBLE       "Use double precision internally"       ON)

if(ANDROID)
    set(_DSP_DEFAULT_AAUDIO ON)
else()
    set(_DSP_DEFAULT_AAUDIO OFF)
endif()
if(WIN32 AND NOT ANDROID)
    set(_DSP_DEFAULT_WASAPI ON)
else()
    set(_DSP_DEFAULT_WASAPI OFF)
endif()
if(APPLE)
    set(_DSP_DEFAULT_COREAUDIO ON)
else()
    set(_DSP_DEFAULT_COREAUDIO OFF)
endif()
if(UNIX AND NOT APPLE AND NOT ANDROID)
    set(_DSP_DEFAULT_ALSA ON)
else()
    set(_DSP_DEFAULT_ALSA OFF)
endif()

option(DSP_BACKEND_AAUDIO    "Build AAudio backend (Android)"       ${_DSP_DEFAULT_AAUDIO})
option(DSP_BACKEND_WASAPI    "Build WASAPI backend (Windows)"       ${_DSP_DEFAULT_WASAPI})
option(DSP_BACKEND_COREAUDIO "Build Core Audio backend (Apple)"     ${_DSP_DEFAULT_COREAUDIO})
option(DSP_BACKEND_ALSA      "Build ALSA backend (Linux)"           ${_DSP_DEFAULT_ALSA})
option(DSP_BACKEND_JACK      "Build JACK backend - stub"            OFF)
option(DSP_BACKEND_PIPEWIRE  "Build PipeWire backend - stub"        OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

if(MSVC)
    set(DSP_OPT_FLAGS /O2 /fp:fast)
    add_compile_definitions(_USE_MATH_DEFINES)
    add_compile_definitions(NOMINMAX)
else()
    set(DSP_OPT_FLAGS -O3 -ffast-math -fno-exceptions -fno-rtti)
    if(DSP_ENABLE_SIMD)
        include(CheckCXXCompilerFlag)
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
            check_cxx_compiler_flag("-mavx2" HAS_AVX2)
            if(HAS_AVX2)
                list(APPEND DSP_OPT_FLAGS -mavx2 -mfma)
            endif()
        endif()
    endif()
endif()
add_compile_options(${DSP_OPT_FLAGS})

set(DSP_LIB_SOURCES
    src/core/processor.cpp
    src/core/dvc.cpp
    src/core/resampler.cpp
    src/utils/math_utils.cpp
    src/audio/ring_buffer.cpp
    src/audio/backends/backend_stubs.cpp
    src/audio/backends/backend_aaudio.cpp
    src/audio/backends/backend_coreaudio.cpp
    src/audio/backends/backend_wasapi.cpp
    src/audio/backends/backend_alsa.cpp
    src/audio/backends/backend_c_api.cpp
    src/realtime/thread_priority.cpp
)

function(configure_dsp_target target_name)
    if(UNIX AND NOT ANDROID)
        find_package(Threads QUIET)
        if(Threads_FOUND)
            target_link_libraries(${target_name} PRIVATE Threads::Threads)
        endif()
    endif()
    target_include_directories(${target_name}
        PUBLIC
            $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
            $<INSTALL_INTERFACE:include>
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/src
    )
    target_compile_definitions(${target_name}
        PRIVATE
            $<$<BOOL:${DSP_USE_DOUBLE}>:DSP_USE_DOUBLE>
            $<$<BOOL:${DSP_BIT_PERFECT}>:DSP_BIT_PERFECT_PATH>
            $<$<BOOL:${DSP_ENABLE_SIMD}>:DSP_SIMD_ENABLED>
    )
    if(DSP_BACKEND_AAUDIO)
        if(ANDROID)
            target_compile_definitions(${target_name} PRIVATE DSP_HAS_AAUDIO)
            find_library(AAUDIO_LIB aaudio)
            if(AAUDIO_LIB)
                target_link_libraries(${target_name} PRIVATE ${AAUDIO_LIB})
            else()
                target_link_libraries(${target_name} PRIVATE aaudio)
            endif()
            find_library(ANDROID_LOG_LIB log)
            if(ANDROID_LOG_LIB)
                target_link_libraries(${target_name} PRIVATE ${ANDROID_LOG_LIB})
            else()
                target_link_libraries(${target_name} PRIVATE log)
            endif()
            find_library(ANDROID_PTHREAD_LIB pthread)
            if(ANDROID_PTHREAD_LIB)
                target_link_libraries(${target_name} PRIVATE ${ANDROID_PTHREAD_LIB})
            endif()
            message(STATUS "AAudio backend enabled for ${target_name}")
        else()
            message(STATUS "DSP_BACKEND_AAUDIO=ON but not ANDROID; AAudio not linked")
        endif()
    endif()
    if(DSP_BACKEND_WASAPI)
        target_compile_definitions(${target_name} PRIVATE DSP_HAS_WASAPI)
        if(WIN32)
            target_link_libraries(${target_name} PRIVATE ole32 uuid avrt)
        endif()
    endif()
    if(DSP_BACKEND_COREAUDIO)
        target_compile_definitions(${target_name} PRIVATE DSP_HAS_COREAUDIO)
        if(APPLE)
            target_link_libraries(${target_name} PRIVATE "-framework AudioToolbox" "-framework AudioUnit" "-framework CoreAudio")
        endif()
    endif()
    if(DSP_BACKEND_ALSA)
        find_package(ALSA QUIET)
        if(ALSA_FOUND)
            target_compile_definitions(${target_name} PRIVATE DSP_HAS_ALSA)
            target_include_directories(${target_name} PRIVATE ${ALSA_INCLUDE_DIRS})
            target_link_libraries(${target_name} PRIVATE ${ALSA_LIBRARIES})
        else()
            find_library(ASOUND_LIB asound)
            if(ASOUND_LIB)
                target_compile_definitions(${target_name} PRIVATE DSP_HAS_ALSA)
                target_link_libraries(${target_name} PRIVATE ${ASOUND_LIB})
            else()
                message(WARNING "DSP_BACKEND_ALSA=ON but libasound not found; ALSA backend disabled")
            endif()
        endif()
    endif()
endfunction()

if(DSP_BUILD_SHARED)
    add_library(dsp_engine SHARED ${DSP_LIB_SOURCES})
    target_compile_definitions(dsp_engine PRIVATE DSP_ENGINE_EXPORTS)
    set_target_properties(dsp_engine PROPERTIES
        OUTPUT_NAME "dsp_engine"
        VERSION ${PROJECT_VERSION}
        SOVERSION ${PROJECT_VERSION_MAJOR}
        WINDOWS_EXPORT_ALL_SYMBOLS ON
    )
    configure_dsp_target(dsp_engine)
endif()

if(DSP_BUILD_STATIC)
    add_library(dsp_engine_static STATIC ${DSP_LIB_SOURCES})
    target_compile_definitions(dsp_engine_static PUBLIC DSP_ENGINE_STATIC)
    set_target_properties(dsp_engine_static PROPERTIES OUTPUT_NAME "dsp_engine")
    configure_dsp_target(dsp_engine_static)
endif()

if(NOT TARGET dsp_engine AND TARGET dsp_engine_static)
    add_library(dsp_engine ALIAS dsp_engine_static)
endif()

if(DSP_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

if(DSP_BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

include(GNUInstallDirs)
if(TARGET dsp_engine AND NOT TARGET dsp_engine_static)
    install(TARGETS dsp_engine EXPORT dsp_engine_targets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
elseif(TARGET dsp_engine_static)
    install(TARGETS dsp_engine_static EXPORT dsp_engine_targets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

message(STATUS "")
message(STATUS "========== DSP ENGINE ${PROJECT_VERSION} ==========")
message(STATUS "Build type         : ${CMAKE_BUILD_TYPE}")
message(STATUS "Shared / Static    : ${DSP_BUILD_SHARED} / ${DSP_BUILD_STATIC}")
message(STATUS "Double precision   : ${DSP_USE_DOUBLE}")
message(STATUS "SIMD               : ${DSP_ENABLE_SIMD}")
message(STATUS "Backend AAudio     : ${DSP_BACKEND_AAUDIO}")
message(STATUS "Backend WASAPI     : ${DSP_BACKEND_WASAPI}")
message(STATUS "Backend CoreAudio  : ${DSP_BACKEND_COREAUDIO}")
message(STATUS "Backend ALSA       : ${DSP_BACKEND_ALSA}")
message(STATUS "==============================")
message(STATUS "")
