import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WebContextMenuLock {
  WebContextMenuLock._();

  static int _lockCount = 0;

  static void acquire() {
    if (!kIsWeb) {
      return;
    }
    if (_lockCount == 0) {
      BrowserContextMenu.disableContextMenu();
    }
    _lockCount += 1;
  }

  static void release() {
    if (!kIsWeb) {
      return;
    }
    if (_lockCount <= 0) {
      _lockCount = 0;
      return;
    }
    _lockCount -= 1;
    if (_lockCount == 0) {
      BrowserContextMenu.enableContextMenu();
    }
  }
}
