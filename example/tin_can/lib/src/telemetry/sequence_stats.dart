// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Loss, reordering and duplicates from u16 datagram sequence numbers.
///
/// Like RTP (RFC 3550 A.1), numbers are extended past the 65535 wrap so a wrap
/// isn't mistaken for a jump backwards.
final class SequenceStats {
  /// Recent sequence numbers remembered to spot duplicates.
  static const int duplicateWindow = 1024;

  static const int _modulus = 0x10000;
  static const int _half = 0x8000;

  int _received = 0;
  int _unique = 0;
  int _reordered = 0;
  int _duplicates = 0;
  int? _last;
  int? _first;
  int? _highest;
  final Set<int> _seen = {};

  void add(int seq) {
    final raw = seq & 0xFFFF;
    _received++;
    _last = raw;
    final highest = _highest;
    if (highest == null) {
      _first = _highest = raw;
      _unique = 1;
      _seen.add(raw);
      return;
    }
    final delta = (raw - highest) & 0xFFFF;
    final extended = delta < _half
        ? highest + delta
        : highest - (_modulus - delta);
    if (_seen.contains(extended)) {
      _duplicates++;
      return;
    }
    _unique++;
    _seen.add(extended);
    if (extended > highest) {
      _highest = extended;
      _forgetBefore(extended - duplicateWindow);
    } else {
      _reordered++;
      if (extended < _first!) _first = extended;
    }
  }

  /// Duplicates included.
  int get received => _received;

  /// From the first sequence number seen to the highest, inclusive.
  int get expected {
    final first = _first;
    final highest = _highest;
    if (first == null || highest == null) return 0;
    return highest - first + 1;
  }

  /// So far: a late arrival still counts back.
  int get lost {
    final missing = expected - _unique;
    return missing < 0 ? 0 : missing;
  }

  double get lossRatio {
    final total = expected;
    return total == 0 ? 0 : lost / total;
  }

  int get reordered => _reordered;

  int get duplicates => _duplicates;

  int? get last => _last;

  void reset() {
    _received = 0;
    _unique = 0;
    _reordered = 0;
    _duplicates = 0;
    _last = null;
    _first = null;
    _highest = null;
    _seen.clear();
  }

  void _forgetBefore(int limit) {
    if (_seen.length > duplicateWindow * 2) {
      _seen.removeWhere((extended) => extended < limit);
    }
  }
}
