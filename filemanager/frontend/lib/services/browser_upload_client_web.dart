import 'dart:js_interop';
import 'package:web/web.dart' as web;

typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);

class BrowserUploadResponse {
  final int statusCode;
  final String body;

  const BrowserUploadResponse({
    required this.statusCode,
    required this.body,
  });
}

Future<BrowserUploadResponse?> uploadWithBrowserFile({
  required Uri uri,
  required String token,
  required String fileName,
  required Object? browserFile,
  UploadProgressCallback? onProgress,
}) async {
  if (browserFile is! web.Blob) {
    return null;
  }
  final web.XMLHttpRequest request = web.XMLHttpRequest();
  final Future<BrowserUploadResponse> responseFuture =
      request.onLoad.first.then(
    (_) => BrowserUploadResponse(
      statusCode: request.status,
      body: request.responseText,
    ),
  );
  onProgress?.call(0, browserFile.size);
  final upload = request.upload;
  upload.addEventListener(
    'progress',
    (web.ProgressEvent event) {
      onProgress?.call(
        event.loaded,
        event.lengthComputable ? event.total : 0,
      );
    }.toJS,
  );
  request.open('POST', uri.toString());
  request.setRequestHeader('Authorization', 'Bearer $token');
  request.setRequestHeader('Content-Type', 'application/octet-stream');
  request.send(browserFile.jsify());
  return responseFuture;
}
