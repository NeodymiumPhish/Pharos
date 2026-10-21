# vcpkg triplet for the libraries Pharos's DuckDB extensions need: static,
# release only, built for the app's minimum macOS.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 26.0)
set(VCPKG_BUILD_TYPE release)

# The macOS 27 SDK declares functions that macOS 26 lacks; a configure check
# that only links (check_function_exists) finds them and the build then fails
# -Werror=partial-availability. Tell each port they are absent.
if(PORT STREQUAL "curl")
    set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DHAVE_PIPE2=0)
endif()
