cmake_minimum_required(VERSION 3.16)
project(face_inference)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# One TLS implementation is shared by the embedded MQTT broker and the local
# HTTPS bridge. Keeping it in-process avoids relying on unavailable system SSL
# libraries on the Dayu OpenHarmony image.
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(MBEDTLS_AS_SUBPROJECT OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/mbedtls EXCLUDE_FROM_ALL)

# NanoMQ is embedded as a static broker core. Optional services stay disabled;
# HTTP and application routing are owned by local_gateway.
set(BUILD_APP_LIB ON CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIB ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_CLIENT OFF CACHE BOOL "" FORCE)
set(BUILD_NANOMQ_CLI OFF CACHE BOOL "" FORCE)
set(BUILD_BENCH OFF CACHE BOOL "" FORCE)
set(NANOMQ_TESTS OFF CACHE BOOL "" FORCE)
set(NNG_TESTS OFF CACHE BOOL "" FORCE)
set(NNG_TOOLS OFF CACHE BOOL "" FORCE)
set(NNG_ENABLE_TLS ON CACHE BOOL "" FORCE)
set(NNG_TLS_ENGINE mbed CACHE STRING "" FORCE)
set(NNG_ENABLE_HTTP OFF CACHE BOOL "" FORCE)
set(ENABLE_ACL OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSLOG OFF CACHE BOOL "" FORCE)
set(NOLOG ON CACHE BOOL "" FORCE)
add_subdirectory(third_party/nanomq EXCLUDE_FROM_ALL)

add_library(face_inference SHARED
    face_inference.cpp
)

add_library(voice_inference SHARED
    voice_inference.cpp
)

add_library(local_gateway SHARED
    local_gateway.cpp
)

set(NCNN_INSTALL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/ncnn/build-ohos-arm64/install")

target_include_directories(face_inference PRIVATE
    "${NCNN_INSTALL_DIR}/include/ncnn"
)

target_link_directories(face_inference PRIVATE
    "${NCNN_INSTALL_DIR}/lib"
)

target_link_libraries(face_inference PUBLIC
    ncnn
    libace_napi.z.so
    librawfile.z.so
)

set(SHERPA_OHPM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../oh_modules/sherpa_onnx")

target_include_directories(voice_inference PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_directories(voice_inference PRIVATE
    "${SHERPA_OHPM_DIR}/libs/${OHOS_ARCH}"
)

target_link_libraries(voice_inference PUBLIC
    sherpa-onnx-c-api
    onnxruntime
    libace_napi.z.so
    librawfile.z.so
)

target_link_libraries(local_gateway PUBLIC
    nanomq
    mbedtls
    mbedx509
    mbedcrypto
    libace_napi.z.so
)

target_include_directories(local_gateway PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/nanomq/nanomq/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/nanomq/nanomq"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/nanomq/nng/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbedtls/include"
)
