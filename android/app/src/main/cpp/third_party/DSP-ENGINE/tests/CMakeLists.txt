# Unit tests and benchmarks for DSP ENGINE

add_executable(unit_tests
    unit_tests.cpp
)
target_include_directories(unit_tests PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(unit_tests PRIVATE dsp_engine)
# Tests use C++ exceptions for assertions; engine is built with -fno-exceptions.
if(NOT MSVC)
    target_compile_options(unit_tests PRIVATE -fexceptions -frtti)
endif()

# On Windows the shared DLL must sit next to the exe or PATH must include it.
if(WIN32 AND TARGET dsp_engine)
    add_custom_command(TARGET unit_tests POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:dsp_engine>
            $<TARGET_FILE_DIR:unit_tests>
        COMMENT "Copy dsp_engine.dll next to unit_tests"
    )
endif()

add_test(NAME unit_tests COMMAND unit_tests)
set_tests_properties(unit_tests PROPERTIES TIMEOUT 30)

add_executable(benchmarks
    benchmarks.cpp
)
target_include_directories(benchmarks PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src
)
target_link_libraries(benchmarks PRIVATE dsp_engine)

if(WIN32 AND TARGET dsp_engine)
    add_custom_command(TARGET benchmarks POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:dsp_engine>
            $<TARGET_FILE_DIR:benchmarks>
        COMMENT "Copy dsp_engine.dll next to benchmarks"
    )
endif()
