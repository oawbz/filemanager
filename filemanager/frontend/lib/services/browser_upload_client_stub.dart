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
  throw UnsupportedError('Browser upload is only available on web.');
}
