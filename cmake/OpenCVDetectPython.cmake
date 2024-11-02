# Extract a Python version without executing the target interpreter. This is
# needed when development files are supplied manually during cross-compilation.
function(_ocv_python_version_from_headers include_dirs version major minor patch)
  foreach(_include_dir ${include_dirs})
    if(EXISTS "${_include_dir}/patchlevel.h")
      file(STRINGS "${_include_dir}/patchlevel.h" _python_major_line
          REGEX "^#[ \t]*define[ \t]+PY_MAJOR_VERSION[ \t]+[0-9]+")
      file(STRINGS "${_include_dir}/patchlevel.h" _python_minor_line
          REGEX "^#[ \t]*define[ \t]+PY_MINOR_VERSION[ \t]+[0-9]+")
      file(STRINGS "${_include_dir}/patchlevel.h" _python_patch_line
          REGEX "^#[ \t]*define[ \t]+PY_MICRO_VERSION[ \t]+[0-9]+")
      string(REGEX REPLACE ".*[ \t]([0-9]+)$" "\\1" _python_major "${_python_major_line}")
      string(REGEX REPLACE ".*[ \t]([0-9]+)$" "\\1" _python_minor "${_python_minor_line}")
      string(REGEX REPLACE ".*[ \t]([0-9]+)$" "\\1" _python_patch "${_python_patch_line}")
      if(_python_major_line AND _python_minor_line AND _python_patch_line)
        set(${version} "${_python_major}.${_python_minor}.${_python_patch}" PARENT_SCOPE)
        set(${major} "${_python_major}" PARENT_SCOPE)
        set(${minor} "${_python_minor}" PARENT_SCOPE)
        set(${patch} "${_python_patch}" PARENT_SCOPE)
        return()
      endif()
    endif()
  endforeach()
endfunction()

# Python used by generators and other build-time tools always runs on the host.
# Do not use FindPython3 here: its result namespace is also used below for the
# target development files and CMake 3.13 has no artifact prefix support.
function(_ocv_find_python_for_build min_version fallback_executable)
  ocv_check_environment_variables(OPENCV_PYTHON_HOST_EXECUTABLE)

  if(OPENCV_PYTHON_HOST_EXECUTABLE)
    set(_host_executable "${OPENCV_PYTHON_HOST_EXECUTABLE}")
    set(_host_executable_is_explicit TRUE)
  elseif(fallback_executable AND NOT CMAKE_CROSSCOMPILING)
    set(_host_executable "${fallback_executable}")
  else()
    unset(_opencv_python_host_executable CACHE)
    find_host_program(_opencv_python_host_executable NAMES python3 python)
    set(_host_executable "${_opencv_python_host_executable}")
    unset(_opencv_python_host_executable CACHE)
  endif()

  if(_host_executable)
    execute_process(
        COMMAND "${_host_executable}" -c
                "import sys; print('%d.%d.%d' % sys.version_info[:3])"
        RESULT_VARIABLE _host_python_process
        OUTPUT_VARIABLE _host_version
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(_host_python_process EQUAL 0
        AND _host_version MATCHES "^3\\."
        AND (NOT min_version OR NOT _host_version VERSION_LESS "${min_version}"))
      set(_host_found TRUE)
    elseif(_host_executable_is_explicit AND NOT OPENCV_SKIP_PYTHON_WARNING)
      message(WARNING
          "OPENCV_PYTHON_HOST_EXECUTABLE='${_host_executable}' is not a usable Python 3 "
          "interpreter with minimum version ${min_version}")
    endif()
  endif()

  set(OPENCV_PYTHON_HOST_FOUND "${_host_found}" CACHE INTERNAL "" FORCE)
  set(OPENCV_PYTHON_HOST_EXECUTABLE "${_host_executable}" CACHE FILEPATH
      "Path to the host Python interpreter used by build tools" FORCE)
  set(OPENCV_PYTHON_HOST_VERSION "${_host_version}" CACHE INTERNAL "" FORCE)
endfunction()

# Find a target Python installation and an independent host interpreter.
#
# preferred_version is an exact target version. min_version applies to both the
# target Python and the host-side build tool. Uppercase output variables retain
# OpenCV's historical cache interface; FindPython3 variables remain internal to
# this function so host and target discovery cannot overwrite each other.
function(find_python preferred_version min_version
    found executable version_string version_major version_minor
    libs_found libs_version_string libraries debug_libraries
    debug_library library_release include_path include_dirs include_dir
    include_dir2 packages_path numpy_include_dirs numpy_version)
  ocv_check_environment_variables(
      ${executable} ${libraries} ${debug_library} ${library_release}
      ${include_path} ${include_dirs} ${include_dir} ${include_dir2}
      ${numpy_include_dirs} OPENCV_PYTHON_HOST_EXECUTABLE
      PYTHON_DEFAULT_EXECUTABLE)

  if(PYTHON_DEFAULT_EXECUTABLE)
    message(DEPRECATION
        "PYTHON_DEFAULT_EXECUTABLE is deprecated; use "
        "OPENCV_PYTHON_HOST_EXECUTABLE instead")
    if(NOT OPENCV_PYTHON_HOST_EXECUTABLE
        OR (DEFINED OPENCV_PYTHON_HOST_EXECUTABLE_LAST
            AND OPENCV_PYTHON_HOST_EXECUTABLE STREQUAL OPENCV_PYTHON_HOST_EXECUTABLE_LAST))
      set(OPENCV_PYTHON_HOST_EXECUTABLE "${PYTHON_DEFAULT_EXECUTABLE}")
    endif()
  endif()

  # Preserve all supported OpenCV inputs before FindPython3 populates its own
  # result variables.
  set(_requested_executable "${${executable}}")
  if(NOT _requested_executable AND Python3_EXECUTABLE)
    set(_requested_executable "${Python3_EXECUTABLE}")
  endif()

  set(_requested_libraries "${${libraries}}")
  set(_requested_debug_libraries "${${debug_libraries}}")
  set(_requested_debug_library "${${debug_library}}")
  set(_requested_library_release "${${library_release}}")
  if(NOT _requested_libraries AND _requested_library_release)
    set(_requested_libraries "${_requested_library_release}")
  elseif(NOT _requested_library_release)
    foreach(_candidate ${_requested_libraries})
      if(NOT _candidate STREQUAL "optimized"
          AND NOT _candidate STREQUAL "debug"
          AND NOT _candidate STREQUAL "general")
        set(_requested_library_release "${_candidate}")
        break()
      endif()
    endforeach()
  endif()
  if(NOT _requested_debug_library AND _requested_debug_libraries)
    foreach(_candidate ${_requested_debug_libraries})
      if(NOT _candidate STREQUAL "optimized"
          AND NOT _candidate STREQUAL "debug"
          AND NOT _candidate STREQUAL "general")
        set(_requested_debug_library "${_candidate}")
        break()
      endif()
    endforeach()
  endif()

  set(_requested_include_dirs "${${include_dirs}}")
  if(NOT _requested_include_dirs)
    if(${include_path})
      set(_requested_include_dirs "${${include_path}}")
    elseif(${include_dir})
      set(_requested_include_dirs "${${include_dir}}")
    endif()
  endif()

  if(NOT CMAKE_CROSSCOMPILING)
    # The host interpreter historically selected the bindings Python too,
    # unless a more specific PYTHON3_EXECUTABLE was supplied.
    if(NOT _requested_executable AND OPENCV_PYTHON_HOST_EXECUTABLE)
      set(_requested_executable "${OPENCV_PYTHON_HOST_EXECUTABLE}")
    endif()
    if(NOT _requested_executable)
      unset(_opencv_python3_path CACHE)
      find_host_program(_opencv_python3_path NAMES python3 python)
      set(_requested_executable "${_opencv_python3_path}")
      unset(_opencv_python3_path CACHE)
    endif()
  endif()

  # Seed the CMake 3.13 FindPython3 cache variables from OpenCV's established
  # uppercase interface. These names are supported by FindPython3 in CMake 3.13.
  if(_requested_executable AND NOT CMAKE_CROSSCOMPILING)
    set(Python3_EXECUTABLE "${_requested_executable}" CACHE FILEPATH
        "Path to the Python3 interpreter" FORCE)
  endif()
  if(_requested_library_release)
    set(Python3_LIBRARY "${_requested_library_release}" CACHE FILEPATH
        "Path to the Python3 library" FORCE)
    set(Python3_LIBRARY_RELEASE "${_requested_library_release}" CACHE FILEPATH
        "Path to the Python3 release library" FORCE)
  endif()
  if(_requested_debug_library)
    set(Python3_LIBRARY_DEBUG "${_requested_debug_library}" CACHE FILEPATH
        "Path to the Python3 debug library" FORCE)
  endif()
  if(_requested_include_dirs)
    list(GET _requested_include_dirs 0 Python3_INCLUDE_DIR)
    set(Python3_INCLUDE_DIR "${Python3_INCLUDE_DIR}" CACHE PATH
        "Path to the Python3 include directory" FORCE)
  endif()

  if(NOT ANDROID AND NOT APPLE_FRAMEWORK)
    if(CMAKE_CROSSCOMPILING)
      # Explicit target artifacts are authoritative and must never be matched
      # against the host interpreter version. A Python library is optional for
      # Unix-like targets because unresolved Python symbols can be provided by
      # the loading interpreter.
      if(_requested_include_dirs AND (_requested_libraries OR NOT WIN32))
        set(_libs_found TRUE)
        set(_libraries "${_requested_libraries}")
        set(_include_dirs "${_requested_include_dirs}")
        set(_debug_libraries "${_requested_debug_libraries}")
        set(_debug_library "${_requested_debug_library}")
        set(_library_release "${_requested_library_release}")
        _ocv_python_version_from_headers("${_include_dirs}"
            _libs_version_string _version_major _version_minor _version_patch)
        if(NOT _libs_version_string AND preferred_version)
          set(_libs_version_string "${preferred_version}")
          string(REPLACE "." ";" _preferred_version_parts "${preferred_version}")
          list(GET _preferred_version_parts 0 _version_major)
          list(LENGTH _preferred_version_parts _preferred_version_parts_count)
          if(_preferred_version_parts_count GREATER 1)
            list(GET _preferred_version_parts 1 _version_minor)
          endif()
        endif()
        set(_version_string "${_libs_version_string}")
      else()
        if(preferred_version)
          find_package(Python3 "${preferred_version}" EXACT COMPONENTS Development)
        elseif(min_version)
          find_package(Python3 "${min_version}" COMPONENTS Development)
        else()
          find_package(Python3 COMPONENTS Development)
        endif()
      endif()
    else()
      if((APPLE OR CMAKE_VERSION VERSION_LESS "3.16") AND _requested_executable
          AND NOT _requested_libraries AND NOT _requested_include_dirs)
        # CMake before 3.16 can fail to locate development files for newer
        # Python installations. The same fallback is also required for the
        # macOS system Python with some newer CMake versions.
        execute_process(
            COMMAND "${_requested_executable}" -c
                    "from sysconfig import *; print(get_config_var('INCLUDEPY'))"
            RESULT_VARIABLE _python_include_process
            OUTPUT_VARIABLE _python_include_fallback
            ERROR_QUIET
            OUTPUT_STRIP_TRAILING_WHITESPACE)
        if(APPLE)
          execute_process(
              COMMAND "${_requested_executable}" -c
                      "from sysconfig import *; print('%s/%s' % (get_config_var('LIBDIR'), get_config_var('LIBRARY').replace('.a', '.dylib' if get_platform().startswith('macos') else '.so')))"
              RESULT_VARIABLE _python_library_process
              OUTPUT_VARIABLE _python_library_fallback
              ERROR_QUIET
              OUTPUT_STRIP_TRAILING_WHITESPACE)
        else()
          execute_process(
              COMMAND "${_requested_executable}" -c
                      "import os, sysconfig; print(os.path.join(sysconfig.get_config_var('LIBDIR') or '', sysconfig.get_config_var('LDLIBRARY') or sysconfig.get_config_var('LIBRARY') or ''))"
              RESULT_VARIABLE _python_library_process
              OUTPUT_VARIABLE _python_library_fallback
              ERROR_QUIET
              OUTPUT_STRIP_TRAILING_WHITESPACE)
        endif()
        if(_python_include_process EQUAL 0 AND _python_library_process EQUAL 0
            AND EXISTS "${_python_include_fallback}/Python.h"
            AND EXISTS "${_python_library_fallback}")
          set(Python3_INCLUDE_DIR "${_python_include_fallback}" CACHE PATH
              "Path to the Python3 include directory" FORCE)
          set(Python3_LIBRARY "${_python_library_fallback}" CACHE FILEPATH
              "Path to the Python3 library" FORCE)
          set(Python3_LIBRARY_RELEASE "${_python_library_fallback}" CACHE FILEPATH
              "Path to the Python3 release library" FORCE)
          set(_python_development_fallback_found TRUE)
        endif()
      endif()

      if(preferred_version)
        find_package(Python3 "${preferred_version}" EXACT COMPONENTS Interpreter Development)
      elseif(min_version)
        find_package(Python3 "${min_version}" COMPONENTS Interpreter Development)
      else()
        find_package(Python3 COMPONENTS Interpreter Development)
      endif()
    endif()

    if(Python3_Interpreter_FOUND AND NOT CMAKE_CROSSCOMPILING)
      set(_found TRUE)
      set(_executable "${Python3_EXECUTABLE}")
      set(_version_string "${Python3_VERSION}")
      set(_version_major "${Python3_VERSION_MAJOR}")
      set(_version_minor "${Python3_VERSION_MINOR}")
      set(_version_patch "${Python3_VERSION_PATCH}")
    endif()

    if(Python3_Development_FOUND)
      set(_libs_found TRUE)
      set(_libraries "${Python3_LIBRARIES}")
      set(_include_dirs "${Python3_INCLUDE_DIRS}")
      set(_library_release "${Python3_LIBRARY_RELEASE}")
      set(_debug_library "${Python3_LIBRARY_DEBUG}")
      if(_debug_library AND NOT _debug_library MATCHES "-NOTFOUND$")
        set(_debug_libraries "${_debug_library}")
      endif()
      set(_libs_version_string "${Python3_VERSION}")
      if(NOT _version_string)
        set(_version_string "${Python3_VERSION}")
        set(_version_major "${Python3_VERSION_MAJOR}")
        set(_version_minor "${Python3_VERSION_MINOR}")
        set(_version_patch "${Python3_VERSION_PATCH}")
      endif()
    elseif(_python_development_fallback_found)
      set(_libs_found TRUE)
      set(_libraries "${_python_library_fallback}")
      set(_library_release "${_python_library_fallback}")
      set(_include_dirs "${_python_include_fallback}")
      set(_libs_version_string "${_version_string}")
    endif()
  elseif(NOT CMAKE_CROSSCOMPILING)
    # Development files are not used for Android and Apple framework builds,
    # but a native interpreter can still be selected for build-time tools.
    if(preferred_version)
      find_package(Python3 "${preferred_version}" EXACT COMPONENTS Interpreter)
    elseif(min_version)
      find_package(Python3 "${min_version}" COMPONENTS Interpreter)
    else()
      find_package(Python3 COMPONENTS Interpreter)
    endif()
    if(Python3_Interpreter_FOUND)
      set(_found TRUE)
      set(_executable "${Python3_EXECUTABLE}")
      set(_version_string "${Python3_VERSION}")
      set(_version_major "${Python3_VERSION_MAJOR}")
      set(_version_minor "${Python3_VERSION_MINOR}")
      set(_version_patch "${Python3_VERSION_PATCH}")
    endif()
  endif()

  if(_include_dirs)
    set(_include_path "${_include_dirs}")
    list(GET _include_dirs 0 _include_dir)
    list(LENGTH _include_dirs _include_dirs_count)
    if(_include_dirs_count GREATER 1)
      list(GET _include_dirs 1 _include_dir2)
    endif()
  endif()
  if(NOT _library_release AND _libraries)
    foreach(_candidate ${_libraries})
      if(NOT _candidate STREQUAL "optimized"
          AND NOT _candidate STREQUAL "debug"
          AND NOT _candidate STREQUAL "general")
        set(_library_release "${_candidate}")
        break()
      endif()
    endforeach()
  endif()

  if((_found OR _libs_found) AND _version_major AND _version_minor)
    set(_version_major_minor "${_version_major}.${_version_minor}")

    if(NOT ${packages_path})
      if(NOT CMAKE_CROSSCOMPILING AND _executable AND UNIX)
        execute_process(
            COMMAND "${_executable}" -c
                    "from sysconfig import get_path; print(get_path('purelib'))"
            RESULT_VARIABLE _python_packages_process
            OUTPUT_VARIABLE _std_packages_path
            ERROR_QUIET
            OUTPUT_STRIP_TRAILING_WHITESPACE)
        if(_python_packages_process EQUAL 0 AND _std_packages_path MATCHES "site-packages")
          set(_packages_path "lib/python${_version_major_minor}/site-packages")
        else()
          set(_packages_path "lib/python${_version_major_minor}/dist-packages")
        endif()
      elseif(NOT CMAKE_CROSSCOMPILING AND _executable AND WIN32)
        get_filename_component(_path "${_executable}" PATH)
        file(TO_CMAKE_PATH "${_path}" _path)
        set(_packages_path "${_path}/Lib/site-packages")
      elseif(UNIX)
        set(_packages_path "lib/python${_version_major_minor}/site-packages")
      elseif(WIN32)
        set(_packages_path "Lib/site-packages")
      endif()
    else()
      set(_packages_path "${${packages_path}}")
    endif()

    if(NOT ANDROID AND NOT IOS AND NOT XROS)
      set(_numpy_include_dirs "${${numpy_include_dirs}}")
      set(_numpy_version "${${numpy_version}}")
      if(NOT _numpy_include_dirs)
        if(CMAKE_CROSSCOMPILING)
          message(STATUS "Cannot probe for Python/Numpy support (because we are cross-compiling OpenCV)")
          message(STATUS "If you want to enable Python/Numpy support, set the following variables:")
          message(STATUS "  PYTHON3_INCLUDE_DIRS (PYTHON3_INCLUDE_PATH is also accepted)")
          message(STATUS "  PYTHON3_LIBRARIES (optional on Unix-like systems)")
          message(STATUS "  PYTHON3_NUMPY_INCLUDE_DIRS")
        elseif(_executable)
          execute_process(
              COMMAND "${_executable}" -c "import numpy; print(numpy.get_include())"
              RESULT_VARIABLE _numpy_process
              OUTPUT_VARIABLE _numpy_include_dirs
              ERROR_QUIET
              OUTPUT_STRIP_TRAILING_WHITESPACE)
          if(NOT _numpy_process EQUAL 0)
            unset(_numpy_include_dirs)
          endif()
        endif()
      endif()

      if(_numpy_include_dirs)
        file(TO_CMAKE_PATH "${_numpy_include_dirs}" _numpy_include_dirs)
        if(CMAKE_CROSSCOMPILING)
          if(NOT _numpy_version)
            set(_numpy_version "undefined - cannot be probed because of the cross-compilation")
          endif()
        elseif(_executable)
          execute_process(
              COMMAND "${_executable}" -c "import numpy; print(numpy.version.version)"
              RESULT_VARIABLE _numpy_process
              OUTPUT_VARIABLE _numpy_version
              ERROR_QUIET
              OUTPUT_STRIP_TRAILING_WHITESPACE)
        endif()
      endif()
    endif()
  endif()

  _ocv_find_python_for_build("${min_version}" "${_executable}")

  # Migrate build directories configured with the historical name.
  set(OPENCV_PYTHON_HOST_EXECUTABLE_LAST "${OPENCV_PYTHON_HOST_EXECUTABLE}"
      CACHE INTERNAL "" FORCE)
  unset(PYTHON_DEFAULT_AVAILABLE CACHE)
  unset(PYTHON_DEFAULT_EXECUTABLE CACHE)
  unset(PYTHON_DEFAULT_VERSION CACHE)

  # Export OpenCV's stable uppercase interface. FORCE keeps aliases coherent
  # when a user changes the selected interpreter in an existing build tree.
  set(${found} "${_found}" CACHE INTERNAL "" FORCE)
  set(${executable} "${_executable}" CACHE FILEPATH "Path to target Python interpreter" FORCE)
  set(${version_string} "${_version_string}" CACHE INTERNAL "" FORCE)
  set(${version_major} "${_version_major}" CACHE INTERNAL "" FORCE)
  set(${version_minor} "${_version_minor}" CACHE INTERNAL "" FORCE)
  set(${libs_found} "${_libs_found}" CACHE INTERNAL "" FORCE)
  set(${libs_version_string} "${_libs_version_string}" CACHE INTERNAL "" FORCE)
  set(${libraries} "${_libraries}" CACHE INTERNAL "Python libraries" FORCE)
  set(${debug_libraries} "${_debug_libraries}" CACHE INTERNAL "Python debug libraries" FORCE)
  set(${debug_library} "${_debug_library}" CACHE FILEPATH "Path to Python debug library" FORCE)
  set(${library_release} "${_library_release}" CACHE FILEPATH "Path to Python release library" FORCE)
  set(${include_path} "${_include_path}" CACHE INTERNAL "Python include path" FORCE)
  set(${include_dirs} "${_include_dirs}" CACHE PATH "Python include directories" FORCE)
  set(${include_dir} "${_include_dir}" CACHE PATH "Python include directory" FORCE)
  set(${include_dir2} "${_include_dir2}" CACHE PATH "Second Python include directory" FORCE)
  set(${packages_path} "${_packages_path}" CACHE STRING "Where to install the Python packages" FORCE)
  set(${numpy_include_dirs} "${_numpy_include_dirs}" CACHE PATH "Path to NumPy headers" FORCE)
  set(${numpy_version} "${_numpy_version}" CACHE INTERNAL "" FORCE)
endfunction()

if(OPENCV_PYTHON_SKIP_DETECTION)
  return()
endif()

set(OPENCV_PYTHON3_VERSION "" CACHE STRING "Exact Python 3 version to build bindings for")
find_python("${OPENCV_PYTHON3_VERSION}" "${MIN_VER_PYTHON3}"
    PYTHON3INTERP_FOUND PYTHON3_EXECUTABLE PYTHON3_VERSION_STRING
    PYTHON3_VERSION_MAJOR PYTHON3_VERSION_MINOR PYTHON3LIBS_FOUND
    PYTHON3LIBS_VERSION_STRING PYTHON3_LIBRARIES
    PYTHON3_DEBUG_LIBRARIES PYTHON3_LIBRARY_DEBUG PYTHON3_LIBRARY_RELEASE
    PYTHON3_INCLUDE_PATH PYTHON3_INCLUDE_DIRS PYTHON3_INCLUDE_DIR
    PYTHON3_INCLUDE_DIR2 PYTHON3_PACKAGES_PATH
    PYTHON3_NUMPY_INCLUDE_DIRS PYTHON3_NUMPY_VERSION)

# Problem in numpy >=1.15 <1.17
OCV_OPTION(PYTHON3_LIMITED_API "Build with Python Limited API (not available with numpy >=1.15 <1.17)" NO
    VISIBLE_IF PYTHON3_NUMPY_VERSION VERSION_LESS "1.15" OR NOT PYTHON3_NUMPY_VERSION VERSION_LESS "1.17")
if(PYTHON3_LIMITED_API)
  set(_default_ver "0x03060000")
  if(PYTHON3_VERSION_STRING VERSION_LESS "3.6")
    # fix for older pythons
    set(_default_ver "0x030${PYTHON3_VERSION_MINOR}0000")
  endif()
  set(PYTHON3_LIMITED_API_VERSION "${_default_ver}" CACHE STRING
      "Minimal Python version for Limited API")
endif()
