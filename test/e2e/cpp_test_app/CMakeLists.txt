cmake_minimum_required(VERSION 3.16)
project(cpp_test_app LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Path to the flutter-skill C++ SDK (override with -DCPP_SDK_DIR=...)
if(NOT DEFINED CPP_SDK_DIR)
    set(CPP_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../sdks/cpp")
endif()

add_subdirectory("${CPP_SDK_DIR}" flutter_skill_sdk)

add_executable(cpp_test_app main.cpp)
target_link_libraries(cpp_test_app PRIVATE flutter_skill)
