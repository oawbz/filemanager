import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_upload_client.dart';

typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);

class ApiService extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _isAdminKey = 'is_admin';
  static const String _shellEnabledKey = 'shell_enabled';
  String? _token;
  String? _username;
  bool _isAdmin = false;
  bool _shellEnabled = false;

  String get baseUrl {
    return '';
  }

  String? get token => _token;
  String? get username => _username;
  bool get isLoggedIn => _token != null;
  bool get isAdmin => _isAdmin;
  bool get shellEnabled => _shellEnabled;

  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    _username = prefs.getString('username');
    _isAdmin = prefs.getBool(_isAdminKey) ?? false;
    _shellEnabled = prefs.getBool(_shellEnabledKey) ?? false;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    final resp = await http.post(
      Uri.parse('api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      _token = data['token'];
      _username = data['username'];
      _isAdmin = data['is_admin'] ?? false;
      _shellEnabled = data['shell_enabled'] ?? false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, _token!);
      await prefs.setString('username', _username!);
      await prefs.setBool(_isAdminKey, _isAdmin);
      await prefs.setBool(_shellEnabledKey, _shellEnabled);
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    _token = null;
    _username = null;
    _isAdmin = false;
    _shellEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove('username');
    await prefs.remove(_isAdminKey);
    await prefs.remove(_shellEnabledKey);
    notifyListeners();
  }

  Future<Map<String, dynamic>> getUserSettings() async {
    final resp = await http.get(
      Uri.parse('api/auth/settings'),
      headers: _authHeaders,
    );
    if (resp.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(resp.body));
    }
    if (_isUnauthorizedResponse(resp)) {
      await _expireAuthSession();
      throw Exception('登录状态已失效，请重新登录');
    }
    throw Exception(_extractError(resp));
  }

  Future<Map<String, dynamic>> updateUserSettings({
    String? username,
    String? oldPassword,
    String? newPassword,
  }) async {
    final Map<String, dynamic> payload = <String, dynamic>{};
    if (username != null) payload['username'] = username;
    if (oldPassword != null && oldPassword.trim().isNotEmpty) {
      payload['old_password'] = oldPassword;
    }
    if (newPassword != null && newPassword.trim().isNotEmpty) {
      payload['new_password'] = newPassword;
    }

    final resp = await http.put(
      Uri.parse('api/auth/settings'),
      headers: _authHeaders,
      body: jsonEncode(payload),
    );
    if (resp.statusCode != 200) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }

    final Map<String, dynamic> data =
        Map<String, dynamic>.from(jsonDecode(resp.body));
    final String nextUsername = (data['username'] ?? '').toString().trim();
    if (nextUsername.isNotEmpty && nextUsername != _username) {
      _username = nextUsername;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('username', nextUsername);
      notifyListeners();
    }
    return data;
  }

  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_token',
      };

  bool _isUnauthorizedResponse(http.Response resp) {
    if (resp.statusCode == 401) {
      return true;
    }
    if (resp.statusCode != 403) {
      return false;
    }
    final String body = resp.body.toLowerCase();
    return body.contains('token') ||
        body.contains('unauthorized') ||
        body.contains('invalid') ||
        body.contains('无效') ||
        body.contains('未授权');
  }

  Future<void> _expireAuthSession() async {
    if (_token == null && _username == null) {
      return;
    }
    await logout();
  }

  String _extractError(http.Response resp) {
    try {
      final data = jsonDecode(resp.body);
      if (data is Map<String, dynamic> && data['error'] != null) {
        return data['error'].toString();
      }
    } catch (_) {
      if (resp.body.isNotEmpty) return resp.body;
    }
    return '请求失败 (${resp.statusCode})';
  }

  String _extractErrorFromBody(int statusCode, String? body) {
    try {
      final dynamic data = jsonDecode(body ?? '');
      if (data is Map<String, dynamic> && data['error'] != null) {
        return data['error'].toString();
      }
    } catch (_) {
      if (body != null && body.isNotEmpty) {
        return body;
      }
    }
    return '请求失败 ($statusCode)';
  }

  Future<http.Response> _postOctetStreamWithProgress({
    required Uri uri,
    required Uint8List bytes,
    UploadProgressCallback? onProgress,
  }) async {
    final http.StreamedRequest request = http.StreamedRequest('POST', uri);
    request.headers.addAll(<String, String>{
      'Authorization': 'Bearer $_token',
      'Content-Type': 'application/octet-stream',
    });

    final int total = bytes.length;
    if (total == 0) {
      onProgress?.call(0, 0);
      await request.sink.close();
      final http.StreamedResponse response = await request.send();
      return http.Response.fromStream(response);
    }

    const int chunkSize = 64 * 1024;
    int sent = 0;
    onProgress?.call(0, total);
    while (sent < total) {
      final int end = (sent + chunkSize < total) ? sent + chunkSize : total;
      request.sink.add(Uint8List.sublistView(bytes, sent, end));
      sent = end;
      onProgress?.call(sent, total);
      await Future<void>.delayed(Duration.zero);
    }
    await request.sink.close();

    final http.StreamedResponse response = await request.send();
    return http.Response.fromStream(response);
  }

  String get _filesBasePath => 'api/files';

  Future<Map<String, dynamic>> listFiles({String path = '/'}) async {
    final uri = Uri.parse(_filesBasePath).replace(queryParameters: {'path': path});
    final resp = await http.get(uri, headers: _authHeaders);
    if (resp.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(resp.body));
    }
    if (_isUnauthorizedResponse(resp)) {
      await _expireAuthSession();
      throw Exception('登录状态已失效，请重新登录');
    }
    throw Exception(_extractError(resp));
  }

  Future<Map<String, dynamic>> getFileContent({required String path}) async {
    final uri = Uri.parse('$_filesBasePath/content').replace(queryParameters: {'path': path});
    final resp = await http.get(uri, headers: _authHeaders);
    if (resp.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(resp.body));
    }
    if (_isUnauthorizedResponse(resp)) {
      await _expireAuthSession();
      throw Exception('登录状态已失效，请重新登录');
    }
    throw Exception(_extractError(resp));
  }

  Future<void> updateFileContent({
    required String path,
    required String content,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/content'),
      headers: _authHeaders,
      body: jsonEncode({'path': path, 'content': content}),
    );
    if (resp.statusCode != 204) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<Map<String, dynamic>> getFileProperties({
    required String path,
    bool calculateSize = false,
  }) async {
    final uri = Uri.parse('$_filesBasePath/properties').replace(queryParameters: {
      'path': path,
      'calculate_size': calculateSize ? 'true' : 'false',
    });
    final resp = await http.get(uri, headers: _authHeaders);
    if (resp.statusCode == 200) {
      return Map<String, dynamic>.from(jsonDecode(resp.body));
    }
    if (_isUnauthorizedResponse(resp)) {
      await _expireAuthSession();
      throw Exception('登录状态已失效，请重新登录');
    }
    throw Exception(_extractError(resp));
  }

  Future<void> createDirectory({
    required String parent,
    required String name,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/mkdir'),
      headers: _authHeaders,
      body: jsonEncode({'parent': parent, 'name': name}),
    );
    if (resp.statusCode != 201) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> createFile({
    required String parent,
    required String name,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/create'),
      headers: _authHeaders,
      body: jsonEncode({'parent': parent, 'name': name}),
    );
    if (resp.statusCode != 201) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> uploadFile({
    required String parent,
    required String fileName,
    required Uint8List bytes,
    Object? browserFile,
    UploadProgressCallback? onProgress,
  }) async {
    final uri = Uri.parse('$_filesBasePath/upload').replace(queryParameters: <String, String>{
      'parent': parent,
      'name': fileName,
    });

    int? statusCode;
    String? responseBody;
    if (kIsWeb) {
      final BrowserUploadResponse? resp = await uploadWithBrowserFile(
        uri: uri,
        token: _token ?? '',
        fileName: fileName,
        browserFile: browserFile,
        onProgress: onProgress,
      );
      if (resp != null) {
        statusCode = resp.statusCode;
        responseBody = resp.body;
      }
    }
    if (statusCode == null) {
      final http.Response resp = await _postOctetStreamWithProgress(
        uri: uri,
        bytes: bytes,
        onProgress: onProgress,
      );
      statusCode = resp.statusCode;
      responseBody = resp.body;
    }

    if (statusCode != 201) {
      if (_isUnauthorizedResponse(http.Response(responseBody ?? '', statusCode))) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractErrorFromBody(statusCode, responseBody));
    }
  }

  String get uploadUrl => '$_filesBasePath/upload';

  Future<void> renameFile({
    required String path,
    required String newName,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/rename'),
      headers: _authHeaders,
      body: jsonEncode({'path': path, 'new_name': newName}),
    );
    if (resp.statusCode != 200) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> deleteFile({required String path}) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/delete'),
      headers: _authHeaders,
      body: jsonEncode({'path': path}),
    );
    if (resp.statusCode != 204) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> copyFiles({
    required List<String> paths,
    required String targetDir,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/copy'),
      headers: _authHeaders,
      body: jsonEncode({'paths': paths, 'target_dir': targetDir}),
    );
    if (resp.statusCode != 200) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> moveFiles({
    required List<String> paths,
    required String targetDir,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/move'),
      headers: _authHeaders,
      body: jsonEncode({'paths': paths, 'target_dir': targetDir}),
    );
    if (resp.statusCode != 200) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> archiveFiles({
    required List<String> paths,
    required String targetDir,
    required String archiveName,
  }) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/archive'),
      headers: _authHeaders,
      body: jsonEncode({
        'paths': paths,
        'target_dir': targetDir,
        'archive_name': archiveName,
      }),
    );
    if (resp.statusCode != 201) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  Future<void> extractArchive({required String path}) async {
    final resp = await http.post(
      Uri.parse('$_filesBasePath/extract'),
      headers: _authHeaders,
      body: jsonEncode({'path': path}),
    );
    if (resp.statusCode != 204) {
      if (_isUnauthorizedResponse(resp)) {
        await _expireAuthSession();
        throw Exception('登录状态已失效，请重新登录');
      }
      throw Exception(_extractError(resp));
    }
  }

  String filesDownloadUrl({required List<String> paths}) {
    final StringBuffer query = StringBuffer('token=${Uri.encodeQueryComponent(_token ?? '')}');
    for (final String path in paths) {
      query.write('&path=${Uri.encodeQueryComponent(path)}');
    }
    return '$_filesBasePath/download?${query.toString()}';
  }

  String filePreviewUrl({required String path}) {
    final Map<String, String> query = <String, String>{
      'token': _token ?? '',
      'path': path,
      'inline': '1',
    };
    return Uri.parse('$_filesBasePath/download').replace(queryParameters: query).toString();
  }

  /// 返回 Shell WebSocket URL（直连本机）
  String shellWsUrl() {
    final uri = Uri.base;
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    if (kIsWeb) {
      final base = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
      return '$wsScheme://${uri.host}:${uri.port}${base}api/shell?token=$_token';
    }
    return 'ws://localhost:8080/api/shell?token=$_token';
  }
}
