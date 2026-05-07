import 'dart:convert';
import 'dart:js_interop';

class NativeBrowserUploadResult {
  final int uploadedCount;
  final int skippedCount;

  const NativeBrowserUploadResult({
    required this.uploadedCount,
    required this.skippedCount,
  });
}

@JS('_callPickAndUploadJson')
external JSPromise<JSString> _callPickAndUploadJson(JSString optsJson);

@JS('_callUploadFilesJson')
external JSPromise<JSString> _callUploadFilesJson(
  JSString optsJson,
  JSArray<JSAny?> files,
);

NativeBrowserUploadResult _parseResultFromJson(String rawJson) {
  if (rawJson.trim().isEmpty) {
    return const NativeBrowserUploadResult(uploadedCount: 0, skippedCount: 0);
  }
  final dynamic data = jsonDecode(rawJson);
  if (data is! Map<String, dynamic>) {
    return const NativeBrowserUploadResult(uploadedCount: 0, skippedCount: 0);
  }
  final dynamic uploaded = data['uploadedCount'];
  final dynamic skipped = data['skippedCount'];
  return NativeBrowserUploadResult(
    uploadedCount: uploaded is num ? uploaded.toInt() : 0,
    skippedCount: skipped is num ? skipped.toInt() : 0,
  );
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
  final String optsJson = jsonEncode(<String, dynamic>{
    'endpointUrl': endpointUrl,
    'token': token,
    'parent': query['parent'] ?? '',
    'multiple': multiple,
    'chunkInitUrl': chunkInitUrl ?? '',
    'chunkUrl': chunkUrl ?? '',
    'completeUrl': completeUrl ?? '',
    'cancelUrl': cancelUrl ?? '',
    'chunkSize': chunkSize ?? 0,
    'retryCount': retryCount ?? 0,
    'accept': accept ?? '',
    'title': title ?? '',
  });

  final JSString raw = await _callPickAndUploadJson(optsJson.toJS).toDart;
  return _parseResultFromJson(raw.toDart);
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
  final String optsJson = jsonEncode(<String, dynamic>{
    'endpointUrl': endpointUrl,
    'token': token,
    'parent': query['parent'] ?? '',
    'chunkInitUrl': chunkInitUrl ?? '',
    'chunkUrl': chunkUrl ?? '',
    'completeUrl': completeUrl ?? '',
    'cancelUrl': cancelUrl ?? '',
    'chunkSize': chunkSize ?? 0,
    'retryCount': retryCount ?? 0,
    'title': title ?? '',
  });

  final List<JSAny?> jsFiles =
      browserFiles.map((Object file) => file as JSAny?).toList();

  final JSString raw =
      await _callUploadFilesJson(optsJson.toJS, jsFiles.toJS).toDart;
  return _parseResultFromJson(raw.toDart);
}
