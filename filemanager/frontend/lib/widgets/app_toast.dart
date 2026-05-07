import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_typography.dart';

enum AppToastType { success, error, warning, info }

class AppToast {
  static final List<OverlayEntry> _entries = <OverlayEntry>[];

  static void show(
    BuildContext context,
    String message, {
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    final OverlayState? overlay = Overlay.of(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (BuildContext overlayContext) {
        final MediaQueryData mediaQuery = MediaQuery.of(overlayContext);
        final _ToastStyle style = _styleFor(type);
        final double width =
            mediaQuery.size.width < 480 ? mediaQuery.size.width - 24 : 320;
        final int index = _entries.indexOf(entry).clamp(0, _entries.length);

        return Positioned(
          top: mediaQuery.padding.top + 16 + index * 76,
          right: 16,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 180),
            builder: (BuildContext context, double value, Widget? child) {
              return Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset((1 - value) * 12, 0),
                  child: child,
                ),
              );
            },
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _remove(entry),
                child: Container(
                  width: width,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: style.borderColor),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.24),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: style.iconBackground,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          style.icon,
                          size: 14,
                          color: style.iconColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          message,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: AppTypography.bodyS,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _entries.add(entry);
    overlay.insert(entry);

    Timer(duration, () {
      _remove(entry);
    });
  }

  static void _remove(OverlayEntry entry) {
    final int index = _entries.indexOf(entry);
    if (index < 0) return;
    _entries.removeAt(index);
    entry.remove();
    for (int i = index; i < _entries.length; i++) {
      _entries[i].markNeedsBuild();
    }
  }

  static _ToastStyle _styleFor(AppToastType type) {
    switch (type) {
      case AppToastType.success:
        return const _ToastStyle(
          icon: Icons.check,
          iconColor: AppColors.successText,
          iconBackground: Color(0x1F3FB950),
          borderColor: Color(0x443FB950),
        );
      case AppToastType.error:
        return const _ToastStyle(
          icon: Icons.close,
          iconColor: AppColors.danger,
          iconBackground: Color(0x1FF85149),
          borderColor: Color(0x44F85149),
        );
      case AppToastType.warning:
        return const _ToastStyle(
          icon: Icons.priority_high,
          iconColor: AppColors.warning,
          iconBackground: Color(0x1FD29922),
          borderColor: Color(0x44D29922),
        );
      case AppToastType.info:
        return const _ToastStyle(
          icon: Icons.info_outline,
          iconColor: AppColors.info,
          iconBackground: Color(0x1F58A6FF),
          borderColor: Color(0x4458A6FF),
        );
    }
  }
}

class _ToastStyle {
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final Color borderColor;

  const _ToastStyle({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.borderColor,
  });
}
