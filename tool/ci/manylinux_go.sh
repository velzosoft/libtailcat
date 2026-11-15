#!/bin/sh
# Copyright (c) 2026 the libtailcat Dart package authors.
# SPDX-License-Identifier: BSD-3-Clause
#
# `go` in a manylinux_2_28 container, so the Linux libraries link against
# glibc 2.28. Use as `build_native.dart --go`; Dart itself can't run there.
# The repo is mounted at its own path, so --out and --source must be inside it.
set -eu

: "${MANYLINUX_IMAGE:?set MANYLINUX_IMAGE to a manylinux_2_28 image}"
: "${MANYLINUX_GOROOT:?set MANYLINUX_GOROOT to a Linux Go toolchain}"

root=$(cd "$(dirname "$0")/../.." && pwd)
cache="$root/.dart_tool/libtailcat/manylinux"
mkdir -p "$cache/mod" "$cache/build"

# Forward the variables the build plan set.
forward=""
for name in CGO_ENABLED GOOS GOARCH GOFLAGS GOTOOLCHAIN CGO_CFLAGS CGO_LDFLAGS; do
  eval "isset=\${$name+yes}"
  if [ "${isset:-}" = yes ]; then forward="$forward -e $name"; fi
done

# shellcheck disable=SC2086
exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$root:$root" \
  -v "$MANYLINUX_GOROOT:/usr/local/go:ro" \
  -v "$cache/mod:/gomod" \
  -v "$cache/build:/gocache" \
  -e GOMODCACHE=/gomod -e GOCACHE=/gocache -e HOME=/tmp \
  $forward \
  -w "$(pwd)" \
  "$MANYLINUX_IMAGE" /usr/local/go/bin/go "$@"
