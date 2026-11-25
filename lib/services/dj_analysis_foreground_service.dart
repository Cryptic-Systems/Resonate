import 'dart:io';

import 'package:flutter/services.dart';

/// Android foreground-execution lease for the serial DJ library scanner.
///
/// This does not perform analysis itself. It keeps the app process eligible
/// to continue the existing Dart/native analysis pipeline while backgrounded.
class DjAnalysisForegroundService {
  static const MethodChannel _channel =
      MethodChannel('com.aetherion.resonate/media_store');

  static Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'startDjAnalysisForegroundService',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopDjAnalysisForegroundService');
    } on PlatformException {
      // The native service also has a bounded wake lock as a fail-safe.
    } on MissingPluginException {
      // Older builds do not have the service channel.
    }
  }
}
