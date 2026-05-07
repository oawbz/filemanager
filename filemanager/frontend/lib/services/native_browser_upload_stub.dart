class NativeBrowserUploadResult {
  final int uploadedCount;
  final int skippedCount;

  const NativeBrowserUploadResult({
    required this.uploadedCount,
    required this.skippedCount,
  });
}

Future<NativeBrowserUploadResult> pickAndUploadFilesWithBrowser({
  required String endpointUrl,
  required String token,
  required Map<String, String> query,
  required bool multiple,
  String? chunkInitUrl,
  String? chunkUrl,
  String? completeUrl,
  String? cancelUrl,
  int? chunkSize,
  int? retryCount,
  String? accept,
  String? title,
}) async {
  throw UnsupportedError('Native browser upload is only available on web.');
}

Future<NativeBrowserUploadResult> uploadBrowserFilesWithBrowser({
  required String endpointUrl,
  required String token,
  required Map<String, String> query,
  required List<Object> browserFiles,
  String? chunkInitUrl,
  String? chunkUrl,
  String? completeUrl,
  String? cancelUrl,
  int? chunkSize,
  int? retryCount,
  String? title,
}) async {
  throw UnsupportedError('Native browser upload is only available on web.');
}
