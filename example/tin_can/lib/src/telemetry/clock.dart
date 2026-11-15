// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Injectable for tests.
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now();
