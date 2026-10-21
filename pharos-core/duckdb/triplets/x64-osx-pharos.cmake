# vcpkg triplet for the libraries Pharos's DuckDB extensions need: static,
# release only, built for the app's minimum macOS.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES x86_64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 26.0)
set(VCPKG_BUILD_TYPE release)
