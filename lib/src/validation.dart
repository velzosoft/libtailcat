// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Returns [port] if it is 1-65535 (0-65535 with [allowAny]), else throws
/// [RangeError]: the C ABI's `uint16_t` would silently wrap it.
int checkPort(int port, {bool allowAny = false}) =>
    RangeError.checkValueInInterval(port, allowAny ? 0 : 1, 65535, 'port');
