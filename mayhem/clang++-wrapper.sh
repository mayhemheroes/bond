#!/bin/sh
# clang++ wrapper: bond's CMake appends `--std=c++11 -Wall -Werror` AFTER CMAKE_CXX_FLAGS
# (add_compile_options), so flags there can't override them. Trailing flags win on the
# clang command line: build with C++14 (boost 1.83's floor) and without -Werror
# (clang 19 warnings this 2015-era codebase predates), leaving upstream files untouched.
exec clang++ "$@" -std=gnu++14 -Wno-error
