import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_service.dart';
import 'screens/login_screen.dart';
import 'screens/file_manager_panel.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiService();
  await api.loadToken();
  runApp(
    ChangeNotifierProvider.value(
      value: api,
      child: const FileManager(),
    ),
  );
}

class FileManager extends StatelessWidget {
  const FileManager({super.key});

  @override
  Widget build(BuildContext context) {
    final bool isLoggedIn = context.watch<ApiService>().isLoggedIn;
    return MaterialApp(
      key: ValueKey<bool>(isLoggedIn),
      title: '文件管理器',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.buildDarkTheme(),
      home: isLoggedIn ? const FileManagerScreen() : const LoginScreen(),
    );
  }
}

class FileManagerScreen extends StatelessWidget {
  const FileManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: const FileManagerPanel(),
    );
  }
}
