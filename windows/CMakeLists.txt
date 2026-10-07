cmake_minimum_required(VERSION 3.21)
project(TUIDockWindows VERSION 0.3.0 LANGUAGES C CXX RC)
if(NOT WIN32)
    message(FATAL_ERROR "The Windows launcher requires Windows and the Windows SDK")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.10 REQUIRED COMPONENTS Widgets Test)

set(vt "${CMAKE_CURRENT_SOURCE_DIR}/../launcher/libvterm")
add_library(vterm_static STATIC
    ${vt}/src/encoding.c ${vt}/src/keyboard.c ${vt}/src/mouse.c
    ${vt}/src/parser.c ${vt}/src/pen.c ${vt}/src/screen.c
    ${vt}/src/state.c ${vt}/src/unicode.c ${vt}/src/vterm.c)
set_target_properties(vterm_static PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON)
target_include_directories(vterm_static PUBLIC ${vt}/include PRIVATE ${vt}/src)
if(MSVC)
    add_compile_options(/utf-8)
    target_compile_options(vterm_static PRIVATE /wd4244 /wd4267 /wd4996)
endif()
add_library(terminal STATIC src/TermView.cpp src/TermView.h src/PtyWin.cpp src/Pty.h
    src/Config.cpp src/Config.h src/Maker.cpp src/Maker.h src/LocalSocket.cpp src/LocalSocket.h
    src/Settings.cpp src/Settings.h src/Launcher.cpp src/Launcher.h
    src/Generator.cpp src/Generator.h)
target_include_directories(terminal PUBLIC src)
target_link_libraries(terminal PUBLIC Qt6::Widgets vterm_static ole32 shell32 propsys uuid ws2_32 dwmapi)
target_compile_definitions(terminal PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
add_executable(tuidock WIN32 src/main.cpp)
target_link_libraries(tuidock PRIVATE terminal)
add_executable(icon_tool src/IconTool.cpp)
target_link_libraries(icon_tool PRIVATE terminal)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/TUIDock.ico"
    COMMAND ${CMAKE_COMMAND} -E env "PATH=$<TARGET_FILE_DIR:Qt6::Core>"
        $<TARGET_FILE:icon_tool> "${CMAKE_CURRENT_SOURCE_DIR}/../app/AppIcon.png" "${CMAKE_CURRENT_BINARY_DIR}/TUIDock.ico"
    DEPENDS icon_tool "${CMAKE_CURRENT_SOURCE_DIR}/../app/AppIcon.png" VERBATIM)
configure_file(icon.rc.in "${CMAKE_CURRENT_BINARY_DIR}/icon.rc" @ONLY)
set_source_files_properties("${CMAKE_CURRENT_BINARY_DIR}/icon.rc" PROPERTIES OBJECT_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/TUIDock.ico")
target_sources(tuidock PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/icon.rc" "${CMAKE_CURRENT_BINARY_DIR}/TUIDock.ico")
qt_add_resources(tuidock app_icon PREFIX "/" BASE "${CMAKE_CURRENT_SOURCE_DIR}/../app" FILES "${CMAKE_CURRENT_SOURCE_DIR}/../app/AppIcon.png")
add_custom_command(TARGET tuidock POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/../launcher/fonts" "$<TARGET_FILE_DIR:tuidock>/fonts")

include(CTest)
if(BUILD_TESTING)
    add_executable(terminal_fixture tests/fixture.cpp)
    target_link_libraries(terminal_fixture PRIVATE Qt6::Core)
    target_compile_definitions(terminal_fixture PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
    add_executable(terminal_tests tests/terminal_tests.cpp)
    set_target_properties(terminal_tests terminal_fixture PROPERTIES WIN32_EXECUTABLE FALSE)
    target_link_libraries(terminal_tests PRIVATE terminal Qt6::Test)
    add_dependencies(terminal_tests terminal_fixture tuidock)
    add_test(NAME terminal COMMAND terminal_tests -o "${CMAKE_BINARY_DIR}/terminal-tests.txt,txt" -o -,txt)
    set_tests_properties(terminal PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 90)
    add_executable(app_tests tests/app_tests.cpp)
    target_link_libraries(app_tests PRIVATE terminal Qt6::Test)
    add_dependencies(app_tests terminal_fixture tuidock)
    add_test(NAME app COMMAND app_tests -o "${CMAKE_BINARY_DIR}/app-tests.txt,txt" -o -,txt)
    set_tests_properties(app PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 90)
endif()
