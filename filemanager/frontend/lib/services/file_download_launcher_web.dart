import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

Future<void> launchFileDownload(String url) async {
  (web.window as JSObject).setProperty('_downloading'.toJS, true.toJS);
  final web.HTMLAnchorElement anchor = web.HTMLAnchorElement()
    ..href = url
    ..style.display = 'none';

  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  Future.delayed(const Duration(seconds: 1), () {
    (web.window as JSObject).setProperty('_downloading'.toJS, false.toJS);
  });
}
