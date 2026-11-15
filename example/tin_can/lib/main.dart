// Copyright (c) 2026 the libtailcat Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

/// Tin Can: a private line between two devices, built on libtailcat.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'src/audio/devices.dart';
import 'src/audio/voice_engine.dart';
import 'src/line/tailcat_network.dart';
import 'src/store/string_store.dart';
import 'src/ui/app.dart';
import 'src/ui/app_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    store: StringStore(PreferencesStore()),
    network: const TailcatNetwork(),
    voice: VoiceEngine(input: RecordInput(), output: PcmSoundOutput()),
  );
  runApp(TinCanApp(controller: controller));
  unawaited(controller.init());
}
