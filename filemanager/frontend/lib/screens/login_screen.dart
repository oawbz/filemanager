import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_typography.dart';
import '../widgets/app_ui.dart';
import '../main.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiService>();
    final ok = await api.login(_usernameCtrl.text.trim(), _passwordCtrl.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const FileManagerScreen()),
      );
    } else {
      setState(() => _error = '用户名或密码错误');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppFrame(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = constraints.maxWidth < 860;
            final Widget intro = Padding(
              padding: EdgeInsets.only(
                  right: compact ? 0 : 32, bottom: compact ? 28 : 0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  Text(
                    '文件管理器',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppTypography.displayM,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    '管理本机文件系统。',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppTypography.titleL,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '支持文件浏览、编辑、上传下载、压缩解压等功能。',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: AppTypography.bodyM,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            );

            final Widget formCard = SizedBox(
              width: compact ? double.infinity : 420,
              child: AppSurface(
                radius: 20,
                color: AppColors.surface,
                borderColor: AppColors.border,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: <Color>[
                                AppColors.primarySoft,
                                AppColors.surfacePanelRaised,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Icon(
                            Icons.terminal,
                            size: 32,
                            color: AppColors.primaryGlow,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          '登录控制台',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: AppTypography.displayM,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '输入管理员凭据以继续访问面板。',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: AppTypography.bodyM,
                          ),
                        ),
                        const SizedBox(height: 28),
                        AutofillGroup(
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _usernameCtrl,
                                style: const TextStyle(color: AppColors.textPrimary),
                                decoration:
                                    _inputDecoration('用户名', Icons.person_outline),
                                validator: (v) => v!.isEmpty ? '请输入用户名' : null,
                                autofillHints: const [AutofillHints.username],
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _passwordCtrl,
                                style: const TextStyle(color: AppColors.textPrimary),
                                decoration:
                                    _inputDecoration('密码', Icons.lock_outline),
                                obscureText: true,
                                validator: (v) => v!.isEmpty ? '请输入密码' : null,
                                autofillHints: const [AutofillHints.password],
                                onFieldSubmitted: (_) => _login(),
                              ),
                            ],
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          AppInfoBanner(
                            message: _error!,
                            icon: Icons.error_outline,
                            tone: AppTone.danger,
                          ),
                        ],
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _login,
                            style: AppButtonStyles.filled(
                              background: AppColors.primaryFill,
                              minimumSize: const Size.fromHeight(48),
                              radius: 10,
                            ),
                            child: _loading
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    '登录',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: AppTypography.section,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );

            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[intro, formCard],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Expanded(child: intro),
                            formCard,
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon) {
    return AppInputDecorations.outlined(
      labelText: label,
      prefixIcon: Icon(icon, color: AppColors.textMuted),
      fillColor: AppColors.backgroundElevated,
    );
  }
}
