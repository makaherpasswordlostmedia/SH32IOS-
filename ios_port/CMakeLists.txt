# =============================================================================
# Silent Hill — iOS app bundle
# =============================================================================
# The iOS analogue of android_port/app/jni/CMakeLists.txt: build SDL2 from the
# submodule, then add the whole of pc_port on top. iOS reuses the PC port
# unchanged rather than forking a HAL the way xbox_port had to, because
# PsyCross selects RENDERER_OGLES on TARGET_OS_IPHONE by itself.
#
# Configure with the plain iOS system name and Ninja (NOT the Xcode generator):
# signing happens off-box with Sideloadly, so Xcode's signing integration buys
# nothing and Ninja keeps this shaped like every other build here.
#
#   cmake -S ios_port -B build-ios -G Ninja \
#         -DCMAKE_SYSTEM_NAME=iOS \
#         -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
#
# See build_ios.sh, which wraps that and packages the .ipa.
# =============================================================================
cmake_minimum_required(VERSION 3.22)
project(SilentHilliOS C CXX OBJC)

if(NOT IOS)
    message(FATAL_ERROR
        "ios_port is an iOS-only project. Configure with -DCMAKE_SYSTEM_NAME=iOS "
        "(see the header of this file), or build pc_port directly for desktop.")
endif()

# PsyCross's logging helpers forward a caller-supplied runtime format string,
# which -Werror=format-security rejects outright. Android hits the same thing
# through the NDK's default flags.
add_compile_options(-Wno-error=format-security)

# Apple deprecated OpenGL ES in iOS 12 and has not removed it in the eight years
# since; PPSSPP still ships GL as its primary iOS backend. Every GL call in
# PsyCross and SDL would otherwise emit a deprecation warning, burying real
# diagnostics in thousands of lines of noise.
add_compile_definitions(GLES_SILENCE_DEPRECATION)

# -----------------------------------------------------------------------------
# 32-bit / armv7 / iOS 9.3 target (original iPad mini, A5 SoC)
# -----------------------------------------------------------------------------
# The A5 never runs arm64 and never exposes OpenGL ES 3 — it tops out at ES2.
# This is a distinct configuration from the normal arm64/ES3 build, not just a
# different -arch flag: PsyCross has to be told to select its ES2 path, and the
# bundle metadata has to stop claiming arm64-only. Select it by architecture
# rather than a separate cache var, since CMAKE_OSX_ARCHITECTURES is already
# the thing toolchain.cmake sets and there is no reason to track the same fact
# twice.
if(CMAKE_OSX_ARCHITECTURES MATCHES "armv7")
    # CACHE + INTERNAL: pc_port/CMakeLists.txt is pulled in below via
    # add_subdirectory and needs to see this too (it gates the Metal.framework
    # link, which doesn't exist in the iOS 9.3 SDK). A plain set() here is
    # only visible in this directory's scope, not the subdirectory's.
    set(SH_IOS_LEGACY_ARMV7 TRUE CACHE INTERNAL "iOS 9.3/armv7 legacy target")
    message(STATUS "ios_port: armv7 target detected — building the ES2/iOS 9.3 configuration")

    # CORRECTION: an earlier version of this file invented a define called
    # RENDERER_OGLES_LEGACY that does not exist anywhere in PsyCross — that
    # was written without having seen PsyCross's actual source (it lives in a
    # git submodule that wasn't checked out at the time) and the claim was
    # wrong. Confirmed against the real source now: PsyCross's iOS branch in
    # PsyX_render.h always selects RENDERER_OGLES with OGLES_VERSION 3,
    # unconditionally, with no existing hook to request ES2. The real,
    # matching hook — PSYCROSS_OGLES_VERSION_OVERRIDE — was added to
    # PsyX_render.h alongside this to actually provide one; see that header
    # for why OGLES_VERSION 2 is what the A5's PowerVR SGX543MP2 needs (no
    # ES3 driver exists for it at all).
    add_compile_definitions(PSYCROSS_OGLES_VERSION_OVERRIDE=2)

    # A5 has 512 MB of RAM shared with the OS; the ES3 renderer's texture
    # streaming budget assumes a device with headroom in the gigabytes.
    # NOTE: SH_LOW_MEMORY_DEVICE is a hook this project still needs to add
    # meaning to elsewhere (e.g. in pc_config.c's default texture/streaming
    # budget) — defining it here only makes the symbol available to code
    # that checks for it, it does not by itself reduce anything.
    add_compile_definitions(SH_LOW_MEMORY_DEVICE)
else()
    set(SH_IOS_LEGACY_ARMV7 FALSE CACHE INTERNAL "iOS 9.3/armv7 legacy target")
endif()

# -----------------------------------------------------------------------------
# SDL2
# -----------------------------------------------------------------------------
# Static, unlike Android: an iOS app may only load dynamic libraries that ship
# inside the signed bundle, and a static SDL avoids that question entirely.
# Pinned to the same commit android_port uses so the two mobile ports never
# diverge on SDL behaviour.
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON  CACHE BOOL "" FORCE)
set(SDL_TEST   OFF CACHE BOOL "" FORCE)
add_subdirectory(SDL)

# pc_port looks for an SDL2 target by name (not find_package) on mobile. SDL's
# static target is SDL2-static; alias it so both mobile ports use one spelling.
if(TARGET SDL2-static AND NOT TARGET SDL2)
    add_library(SDL2 ALIAS SDL2-static)
endif()

# -----------------------------------------------------------------------------
# iOS-specific sources, compiled into the game target
# -----------------------------------------------------------------------------
# Platform code lives here, never in pc_port/src or src/ — same rule the other
# ports follow.
set(SH_IOS_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_paths.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_bootstrap.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_ra_http.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ios_ra_login.m"
    CACHE INTERNAL "iOS platform sources compiled into the game target")

# pc_port owns the bundle POST_BUILD steps (ibtool, asset copy) because
# add_custom_command in TARGET form only works in the directory that created the
# target. It needs to find Resources/ from there.
set(SH_IOS_PORT_DIR "${CMAKE_CURRENT_SOURCE_DIR}"
    CACHE INTERNAL "ios_port source directory")

# -----------------------------------------------------------------------------
# The game
# -----------------------------------------------------------------------------
add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../pc_port"
    "${CMAKE_CURRENT_BINARY_DIR}/pc_port"
)

# -----------------------------------------------------------------------------
# Bundle metadata
# -----------------------------------------------------------------------------
# The bundle identifier is load-bearing and must not change: re-signing keeps
# the app's container (and therefore the user's disc image and saves) only while
# it stays the same. Matches the Android applicationId.
set(SH_IOS_BUNDLE_ID "com.silenthill.port" CACHE STRING "iOS bundle identifier")

# Configure the plist ourselves rather than leaning on CMake's
# MACOSX_BUNDLE_INFO_PLIST substitution, which only promises to fill the
# MACOSX_BUNDLE_* names. The keys that decide whether an installer accepts the
# bundle at all are ours, so resolve them explicitly here.
set(SH_IOS_EXECUTABLE "SilentHill")
if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
    set(SH_IOS_PLATFORM      "iPhoneSimulator")
    set(SH_IOS_PLATFORM_NAME "iphonesimulator")
else()
    set(SH_IOS_PLATFORM      "iPhoneOS")
    set(SH_IOS_PLATFORM_NAME "iphoneos")
endif()
# The SDK version the bundle claims has to be the one it was actually built
# against, so ask the toolchain instead of hardcoding a number that rots.
execute_process(COMMAND xcrun --sdk "${SH_IOS_PLATFORM_NAME}" --show-sdk-version
                OUTPUT_VARIABLE SH_IOS_SDK_VERSION
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET)
if(NOT SH_IOS_SDK_VERSION)
    set(SH_IOS_SDK_VERSION "${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif()
set(SH_IOS_SDK_NAME "${SH_IOS_PLATFORM_NAME}${SH_IOS_SDK_VERSION}")
set(SH_IOS_DEPLOYMENT_TARGET "${CMAKE_OSX_DEPLOYMENT_TARGET}")

# UIRequiredDeviceCapabilities has to name the arch actually shipped, or
# installd refuses the bundle before it ever gets to a code-signature check.
if(SH_IOS_LEGACY_ARMV7)
    set(SH_IOS_REQUIRED_CAPABILITY "armv7")
else()
    set(SH_IOS_REQUIRED_CAPABILITY "arm64")
endif()

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Resources/Info.plist.in"
               "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

set_target_properties(SilentHillPC PROPERTIES
    OUTPUT_NAME "SilentHill"
    MACOSX_BUNDLE_BUNDLE_NAME "Silent Hill"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${SH_IOS_BUNDLE_ID}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    # Signed off-box; a CI build with no keychain cannot sign at all.
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
)

# The bundle POST_BUILD steps (ibtool for the launch storyboard, and copying
# the port's shipped assets in) live in pc_port/CMakeLists.txt under if(IOS),
# because add_custom_command in TARGET form only works in the directory that
# created the target.

message(STATUS "iOS bundle: ${SH_IOS_BUNDLE_ID} (arch ${CMAKE_OSX_ARCHITECTURES}, "
               "min iOS ${CMAKE_OSX_DEPLOYMENT_TARGET})")
