#!/bin/sh
# clang wrapper: drop -Werror added by bond's CMake after CMAKE_C_FLAGS (see clang++-wrapper.sh).
exec clang "$@" -Wno-error
