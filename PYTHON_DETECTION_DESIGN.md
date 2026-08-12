# OpenCV Python Detection Design Notes

## Purpose

This document records the current Python detection design, its behavioral
contract, and the selected target-based replacement interface. It is intended
to guide a future cleanup of
`cmake/OpenCVDetectPython.cmake` without regressing native builds,
cross-compilation, standalone Python packaging, or CMake 3.13 support.

The central rule is:

> Python used to run generators belongs to the host. Python headers,
> libraries, NumPy headers, ABI version, and package layout belong to the
> target.

The selected replacement design strengthens that separation: target Python
discovery never searches for, executes, accepts, or returns a Python
interpreter, in either native or cross builds. The only interpreter known to
OpenCV is the independently selected host interpreter.

Host and target Python installations may have different versions and
architectures.

## Current high-level architecture

```text
OpenCV cache/environment inputs
                |
                v
       Capture requested values
                |
        +-------+--------+
        |                |
   Native build      Cross build
        |                |
 FindPython3 with    Explicit target
 Interpreter and    headers/libraries,
 Development        or Development-only
        |            FindPython3
        +-------+--------+
                |
                v
     Normalize target results
                |
                v
     Export uppercase variables

Separately:

OPENCV_PYTHON_HOST_EXECUTABLE
                |
                v
 find_host_program() and version validation
                |
                v
OPENCV_PYTHON_HOST_* results
```

`find_python()` is therefore not just a wrapper around CMake's
`FindPython3`. It is an adapter between OpenCV configuration inputs, CMake's
Python discovery, cross-compilation artifacts, and variables consumed by the
rest of the OpenCV build.

## Current `find_python()` interface

The current signature is conceptually:

```cmake
function(find_python
    preferred_version
    min_version

    found
    executable
    version_string
    version_major
    version_minor

    libs_found
    libs_version_string
    libraries
    debug_libraries
    debug_library
    library_release

    include_path
    include_dirs
    include_dir
    include_dir2

    packages_path
    numpy_include_dirs
    numpy_version)
```

### Value parameters

The first two parameters are values:

- `preferred_version` is actually an exact target Python version.
- `min_version` is the minimum supported version for target Python and the
  host Python used by build tools.

More accurate names would be:

```text
target_exact_version
minimum_python_version
```

### Variable-name parameters

Every remaining argument is the name of a destination variable. For example,
the argument named `libraries` may contain the literal string
`PYTHON3_LIBRARIES`.

The current value is read through double dereferencing:

```cmake
set(_requested_libraries "${${libraries}}")
```

The result is written through the same name:

```cmake
set(${libraries} "${_libraries}" CACHE INTERNAL "Python libraries" FORCE)
```

Consequently, many artifact parameters are effectively in/out variables:

```text
existing cache value -> requested artifact
detected value       -> resulting cache value
```

This variable-name interface allows the function to populate two namespaces:

- Normal configuration uses `PYTHON3_*` variables.
- Standalone Python packaging uses `PYTHON_*` variables.

## Target Python results

### Interpreter and version

The target interpreter group is:

```text
found
executable
version_string
version_major
version_minor
```

In a native build, the interpreter is runnable and its version comes from
`FindPython3`.

In a cross build, the target interpreter must not be executed. The target
version is read from `patchlevel.h`, so target development files can be valid
even when `found` is false and `executable` is empty.

### Development artifacts

The development group is:

```text
libs_found
libs_version_string
libraries
debug_libraries
debug_library
library_release
include_path
include_dirs
include_dir
include_dir2
```

`libs_found` means that the target development artifacts needed by the Python
bindings are available. It does not necessarily mean that a Python library is
present: on some Unix-like cross targets, unresolved Python symbols are
provided by the interpreter that loads the extension.

OpenCV ultimately compiles with the include-directory list and links with the
library list. Several singular and alias variables exist because of the old
`FindPythonLibs` interface and Windows Debug/Release handling.

### Package installation and NumPy

The remaining group is:

```text
packages_path
numpy_include_dirs
numpy_version
```

`packages_path` is OpenCV installation policy. It is not a CMake
`FindPython3` hint. CMake exposes `Python3_SITELIB` and `Python3_SITEARCH` as
detected results, but no `Python3_PACKAGES_PATH` input exists, including in
CMake 4.3.

In native builds, NumPy information can be obtained by executing the target
interpreter. In cross builds, target NumPy headers must be provided explicitly.

## Host Python interface

Host Python is not returned through the positional output list. It is exposed
through fixed cache variables:

```cmake
OPENCV_PYTHON_HOST_FOUND
OPENCV_PYTHON_HOST_EXECUTABLE
OPENCV_PYTHON_HOST_VERSION
```

Host selection order is:

1. Explicit `OPENCV_PYTHON_HOST_EXECUTABLE`.
2. The selected target interpreter as a fallback, only in a native build.
3. `find_host_program(NAMES python3 python)`.

OpenCV executes the selected host interpreter to confirm that it is a
supported Python 3.

The host interpreter is used for binding generators, Java/JavaScript/Objective-C
generators, documentation processing, lint, and other build-time scripts.

## Native discovery

For a native build, OpenCV selects an interpreter and calls approximately:

```cmake
find_package(Python3 ... COMPONENTS Interpreter Development)
```

Explicit OpenCV values are captured before `FindPython3` runs. Where needed,
they are translated into the singular camel-case cache variables used by the
CMake 3.13 implementation, such as:

```text
Python3_EXECUTABLE
Python3_LIBRARY_RELEASE
Python3_LIBRARY_DEBUG
Python3_INCLUDE_DIR
```

Direct artifact specification was not documented until CMake 3.16. Using
these variables with CMake 3.13 relies on the implementation of its
`FindPython3` module rather than a documented 3.13 interface.

For CMake versions before 3.16, and for affected macOS installations, OpenCV
may query the interpreter's `sysconfig` data and seed the development artifact
paths before invoking `FindPython3`.

## Cross-compilation discovery

Cross builds must never execute the target interpreter.

When explicit target artifacts are supplied, OpenCV consumes them itself
instead of expecting CMake to interpret uppercase OpenCV variables as hints.
The important values are conceptually:

```text
target include directories
target libraries, optional on supported Unix-like targets
target NumPy include directories
```

OpenCV reads the target Python version from the supplied headers.

If explicit artifacts are not supplied, OpenCV may call:

```cmake
find_package(Python3 ... COMPONENTS Development)
```

In that case, the CMake toolchain and root-path configuration must make
`FindPython3` search the target environment.

## Required behavioral contract

Any future implementation must satisfy these rules:

1. Host and target Python versions may differ.
2. Target discovery must never request the `FindPython3` `Interpreter`
   component, in native or cross builds.
3. Explicit target artifacts are authoritative during cross-compilation.
4. Target version is always validated from target development metadata,
   ultimately `patchlevel.h`, rather than from an interpreter.
5. Native builds may use one Python installation for both roles.
6. Generators always use `OPENCV_PYTHON_HOST_EXECUTABLE`.
7. Python bindings require a host generator, target Python headers, and target
   NumPy headers.
8. The implementation must remain compatible with CMake 3.13.
9. The macOS/pre-CMake-3.16 development-artifact fallback must remain until it
   is validated as unnecessary on supported configurations.

## Confirmed cleanup decisions

- Use `OPENCV_PYTHON_HOST_*` for the build-time interpreter. The historical
  `PYTHON_DEFAULT_*` name came from the former Python 2/Python 3 design and no
  longer describes its role.
- Do not expose uppercase `PYTHON3_LIBRARY`.
- Do not describe uppercase `PYTHON3_*` values as CMake hints. They are OpenCV
  inputs that the wrapper consumes or translates.
- Compatibility with every historical Python cache alias is not a design
  requirement for the future cleanup.
- Raw target Python libraries, Python include directories, and NumPy include
  directories are discovery inputs and private implementation data. They must
  not be output variables of the replacement `find_python()` interface.
- The historical `include_path`, primary include directory, and secondary
  include directory outputs will be removed.
- Target Python and NumPy build requirements will be represented by the CMake
  interface target `opencv_python3_target`.
- The existence of `opencv_python3_target` replaces a separate
  development-artifacts-found output.
- Target discovery will not accept or return an executable. In particular,
  `PYTHON3_EXECUTABLE` is not part of the replacement target interface.
- Host discovery uses an explicit `OPENCV_PYTHON_HOST_EXECUTABLE` or
  `find_host_program()`. It no longer has a "selected target interpreter"
  fallback because target discovery produces no executable.
- `FindPython3` will be called only for target development components. The
  `Interpreter` and `NumPy` components are not requested because NumPy
  discovery through `FindPython3` may implicitly require an interpreter.
- Python package installation policy will be handled outside artifact
  discovery. `PYTHON3_PACKAGES_PATH` is not part of the replacement
  `find_python()` interface.

## Selected target-based design

The selected discovery flow is:

```text
find_host_program(python3/python)       FindPython3 Development only
              |                                      |
              v                                      v
 OPENCV_PYTHON_HOST_*                  target headers/link requirements
              |                                      |
              +--> generators                parse patchlevel.h
              |
              +--> optional native NumPy query       |
                         |                            |
                         +------------+---------------+
                                      v
                           opencv_python3_target
```

The two sides may resolve to the same Python installation in a native build,
but they are still discovered for different roles. Target discovery does not
reuse a host executable as a target result.

### Responsibility of `find_python()`

The replacement `find_python()` function will:

1. Discover or validate target Python metadata and development artifacts.
2. Accept explicit raw artifacts for CMake 3.13 and cross-compilation.
3. Keep all raw library and include paths private to the function.
4. Create `opencv_python3_target` when the target Python and NumPy development
   requirements are complete.
5. Store NumPy usage requirements and NumPy metadata on the result target.
6. Return only target Python ABI version metadata still needed by existing
   configuration and packaging code.

The function will not return Python libraries, Python include directories,
NumPy include directories, NumPy version, individual Debug/Release libraries,
an executable, or compatibility include aliases. It will never request or
execute a target interpreter.

### Replacement interface

Use keyword arguments so inputs and output destinations are visible at the
call site. `cmake_parse_arguments()` is available with CMake 3.13.

```cmake
find_python(
    TARGET opencv_python3_target

    EXACT_VERSION "${OPENCV_PYTHON3_VERSION}"
    MINIMUM_VERSION "${MIN_VER_PYTHON3}"

    LIBRARIES "${PYTHON3_LIBRARIES}"
    INCLUDE_DIRS "${PYTHON3_INCLUDE_DIRS}"
    NUMPY_INCLUDE_DIRS "${PYTHON3_NUMPY_INCLUDE_DIRS}"
    NUMPY_VERSION "${PYTHON3_NUMPY_VERSION}"

    OUT_VERSION PYTHON3_VERSION_STRING
    OUT_VERSION_MAJOR PYTHON3_VERSION_MAJOR
    OUT_VERSION_MINOR PYTHON3_VERSION_MINOR)
```

Input keywords contain values. `OUT_*` keywords contain destination variable
names. Raw artifact inputs may be empty.

Conceptually, the implementation begins with:

```cmake
function(find_python)
  set(_one_value_args
      TARGET
      EXACT_VERSION
      MINIMUM_VERSION
      NUMPY_VERSION
      OUT_VERSION
      OUT_VERSION_MAJOR
      OUT_VERSION_MINOR)
  set(_multi_value_args
      LIBRARIES
      INCLUDE_DIRS
      NUMPY_INCLUDE_DIRS)
  cmake_parse_arguments(PYTHON "" "${_one_value_args}"
                        "${_multi_value_args}" ${ARGN})
  # Discovery and target construction follow.
endfunction()
```

`EXACT_VERSION` is an exact target ABI selection. `MINIMUM_VERSION` is the
minimum supported Python version. Both constraints are checked against target
development metadata, not interpreter output.

`LIBRARIES`, `INCLUDE_DIRS`, and `NUMPY_INCLUDE_DIRS` are OpenCV artifact
inputs, not CMake `FindPython3` hints. They allow an existing toolchain or
cross-build command to provide target artifacts explicitly. They are consumed
by `find_python()` and are not exported again.

If Python development artifacts are not supplied, discovery uses only:

```cmake
find_package(Python3 ... COMPONENTS Development)
```

It must not add `Interpreter` or `NumPy`. After discovery, OpenCV reads
`patchlevel.h` from the selected target include directory and checks
`EXACT_VERSION` and `MINIMUM_VERSION` itself. This gives native and cross
builds the same target-version rule and avoids relying on whether a particular
CMake release reports a version without an interpreter.

Target NumPy discovery is separate from `FindPython3`:

- Explicit `NUMPY_INCLUDE_DIRS` and `NUMPY_VERSION` are authoritative.
- In a native build, the host-discovery layer may execute the host Python to
  query NumPy, then pass those values to `find_python()` when the host and
  target Python installations are known to match.
- If host and target differ, target NumPy information must be provided by the
  toolchain or configuration even in a native build.
- In a cross build, target NumPy information must be provided explicitly and
  the host NumPy installation is never used as a substitute.

Thus the target function consumes NumPy results but never discovers an
interpreter to obtain them.

The output metadata is intentionally small:

```text
OUT_VERSION        Target Python ABI version.
OUT_VERSION_MAJOR  Target Python major version.
OUT_VERSION_MINOR  Target Python minor version.
```

There is no `OUT_FOUND` or `OUT_EXECUTABLE`: target discovery has no
interpreter result. There is no `OUT_DEVELOPMENT_FOUND`: the existence of the
requested `TARGET` indicates that all required target development usage
requirements are available.

### Construction of `opencv_python3_target`

`opencv_python3_target` represents everything required to compile and link the
`cv2` extension against the target Python and NumPy installations. It also
owns the detected or explicitly supplied NumPy version as target metadata.

When development-only `FindPython3` provides `Python3::Module`, use it for the
Python compile and link requirements. NumPy remains an explicit target input:

```cmake
add_library(opencv_python3_target INTERFACE)
target_link_libraries(opencv_python3_target INTERFACE Python3::Module)
target_include_directories(opencv_python3_target SYSTEM INTERFACE
    "${_target_numpy_include_dirs}")
```

The design intentionally does not consume `Python3::NumPy`, because requesting
the `NumPy` component may also cause `FindPython3` to search for an
interpreter. NumPy headers and metadata are attached to OpenCV's result target
directly.

After discovery, record NumPy metadata on the result target:

```cmake
set_property(TARGET opencv_python3_target PROPERTY
    OPENCV_PYTHON_NUMPY_VERSION "${_target_numpy_version}")
```

Code that only needs to display or package the detected version can query it:

```cmake
get_target_property(PYTHON3_NUMPY_VERSION opencv_python3_target
                    OPENCV_PYTHON_NUMPY_VERSION)
```

The custom property is metadata only. NumPy headers propagate through the
target's interface include directories.

For CMake 3.13, or when explicit cross-compilation artifacts bypass
`FindPython3`, construct the same target from private local values:

```cmake
add_library(opencv_python3_target INTERFACE)
target_include_directories(opencv_python3_target SYSTEM INTERFACE
    "${_target_python_include_dirs}"
    "${_target_numpy_include_dirs}")

if(WIN32 OR OPENCV_FORCE_PYTHON_LIBS)
  target_link_libraries(opencv_python3_target INTERFACE
      ${_target_python_libraries})
endif()
```

The fallback must preserve current extension-module linking behavior:

- Linux normally resolves Python C API symbols from the loading interpreter
  and does not link `libpython` unless `OPENCV_FORCE_PYTHON_LIBS` is enabled.
- macOS uses dynamic symbol lookup rather than linking `libpython`.
- Windows links the appropriate Python import library, including configuration
  selection for Debug and Release builds.
- Limited-API linking must preserve the existing Windows library-name
  adjustment, or use `Python3::SABIModule` where the available CMake version
  supports it.

All platform-specific link options that describe Python extension-module usage
should propagate through `opencv_python3_target` where CMake 3.13 permits it.

### Downstream use

The Python binding module will no longer add Python or NumPy include directories
directly and will no longer inspect raw Python library variables.

Availability becomes:

```cmake
if(NOT OPENCV_PYTHON_HOST_FOUND OR NOT TARGET opencv_python3_target)
  ocv_module_disable(python3)
endif()
```

The binding target consumes one dependency:

```cmake
ocv_target_link_libraries(${the_module} PRIVATE opencv_python3_target)
```

`opencv_python3_target` supplies Python headers, NumPy headers, platform link
requirements, and any required Python libraries transitively. Its
`OPENCV_PYTHON_NUMPY_VERSION` property supplies the NumPy version without a
separate `find_python()` output parameter.

Host Python remains separate. Generator commands continue to use
`OPENCV_PYTHON_HOST_EXECUTABLE`; the target interface must never contain or
select the host interpreter.

### Extension-module suffix

The `cv2` filename suffix is target packaging metadata, not a reason to find a
target interpreter. `PYTHON3_CVPY_SUFFIX` remains the authoritative explicit
input and is especially important when host and target Python differ.

When it is not supplied, OpenCV may use development-only ABI metadata exposed
by newer CMake versions. A native build may query the host interpreter only
when the host and target installations are known to match. Otherwise the
configuration must require an explicit suffix or use an intentionally generic
platform suffix such as `.so`/`.pyd`. Suffix discovery must never reintroduce
a target `EXECUTABLE` parameter.

## Problems to address in a future interface

The current interface works, but it is difficult to reason about because:

- It has twenty positional arguments.
- Input values and output destinations look identical at the call site.
- Several parameters are both inputs and outputs.
- It exposes redundant aliases and individual library representations.
- It mixes target artifact discovery with package-installation policy.
- Host discovery is a hidden side effect.
- Results are written to the global cache instead of being ordinary function
  results.

The selected keyword interface makes requested artifacts explicit inputs and
metadata results explicit outputs. Implementation-only singular library paths
required by CMake 3.13 remain private to the detector. Both normal and
standalone configurations can choose their metadata destination variables
while consuming an interface target instead of raw artifact outputs.
