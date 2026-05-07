import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_typography.dart';

enum AppTone { neutral, info, success, warning, danger }

enum AppDialogSize { compact, medium, large, xlarge }

class _AppTonePalette {
  final Color background;
  final Color foreground;
  final Color border;

  const _AppTonePalette({
    required this.background,
    required this.foreground,
    required this.border,
  });
}

_AppTonePalette _paletteForTone(AppTone tone) {
  switch (tone) {
    case AppTone.info:
      return const _AppTonePalette(
        background: Color(0x1F58A6FF),
        foreground: AppColors.primary,
        border: Color(0x4458A6FF),
      );
    case AppTone.success:
      return const _AppTonePalette(
        background: Color(0x1F3FB950),
        foreground: AppColors.successText,
        border: Color(0x443FB950),
      );
    case AppTone.warning:
      return const _AppTonePalette(
        background: Color(0x1FD29922),
        foreground: AppColors.warning,
        border: Color(0x44D29922),
      );
    case AppTone.danger:
      return const _AppTonePalette(
        background: Color(0x1FF85149),
        foreground: AppColors.danger,
        border: Color(0x44F85149),
      );
    case AppTone.neutral:
      return const _AppTonePalette(
        background: AppColors.surfaceMuted,
        foreground: AppColors.textMuted,
        border: AppColors.border,
      );
  }
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = '关闭弹窗',
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (
      BuildContext dialogContext,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
    ) {
      return SafeArea(child: builder(dialogContext));
    },
    transitionBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      final Animation<double> fade = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      final Animation<Offset> slide = Tween<Offset>(
        begin: const Offset(0, 0.03),
        end: Offset.zero,
      ).animate(fade);
      final Animation<double> scale = Tween<double>(
        begin: 0.985,
        end: 1,
      ).animate(fade);
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(
          position: slide,
          child: ScaleTransition(scale: scale, child: child),
        ),
      );
    },
  );
}

class AppSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? color;
  final Color? borderColor;

  const AppSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 10,
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? AppColors.border),
      ),
      child: child,
    );
  }
}

class AppFrame extends StatelessWidget {
  final Widget child;

  const AppFrame({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AppColors.backgroundCanvas,
            AppColors.background,
            AppColors.backgroundElevated,
          ],
          stops: <double>[0, 0.45, 1],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            top: -120,
            right: -80,
            child: IgnorePointer(
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.08),
                ),
              ),
            ),
          ),
          Positioned(
            left: -100,
            bottom: -140,
            child: IgnorePointer(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceMuted.withValues(alpha: 0.32),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class AppSectionLabel extends StatelessWidget {
  final String label;

  const AppSectionLabel({
    super.key,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textSubtle,
          fontSize: AppTypography.caption,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

class AppBadge extends StatelessWidget {
  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final EdgeInsetsGeometry? padding;
  final TextAlign textAlign;
  final AppTone tone;

  const AppBadge({
    super.key,
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
    this.padding,
    this.textAlign = TextAlign.center,
    this.tone = AppTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final _AppTonePalette palette = _paletteForTone(tone);
    return Container(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor ?? palette.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        textAlign: textAlign,
        style: TextStyle(
          color: foregroundColor ?? palette.foreground,
          fontSize: AppTypography.caption,
        ),
      ),
    );
  }
}

class AppActionButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback onTap;
  final IconData icon;
  final String? label;
  final Color color;
  final bool iconOnly;
  final bool enabled;
  final bool compact;

  const AppActionButton({
    super.key,
    required this.tooltip,
    required this.onTap,
    required this.icon,
    this.label,
    this.color = AppColors.actionMuted,
    this.iconOnly = false,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color resolvedColor = enabled ? color : color.withValues(alpha: 0.45);
    final Widget button;
    if (iconOnly && !compact) {
      button = SizedBox(
        width: 36,
        height: 36,
        child: OutlinedButton(
          onPressed: enabled ? onTap : null,
          style: AppButtonStyles.outlined(
            background: AppColors.surface,
            minimumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
            radius: 8,
          ),
          child: Icon(icon, size: 16, color: resolvedColor),
        ),
      );
    } else {
      button = InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: iconOnly ? 30 : null,
          height: iconOnly ? 28 : null,
          padding: iconOnly
              ? null
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(color: resolvedColor.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: iconOnly
              ? Icon(icon, size: 14, color: resolvedColor)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 13, color: resolvedColor),
                    if ((label ?? '').isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Text(
                        label!,
                        style: TextStyle(
                            color: resolvedColor,
                            fontSize: AppTypography.bodyS),
                      ),
                    ],
                  ],
                ),
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 450),
      child: button,
    );
  }
}

class AppPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final double iconSize;

  const AppPrimaryButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.iconSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      style: AppButtonStyles.filled(),
      icon: Icon(icon, size: iconSize),
      label: Text(label),
    );
  }
}

class AppSecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData? icon;
  final String label;
  final double iconSize;

  const AppSecondaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.iconSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (icon == null) {
      return ElevatedButton(
        onPressed: onPressed,
        style: AppButtonStyles.subtle(),
        child: Text(label),
      );
    }
    return ElevatedButton.icon(
      onPressed: onPressed,
      style: AppButtonStyles.subtle(),
      icon: Icon(icon, size: iconSize),
      label: Text(label),
    );
  }
}

class AppOverflowMenuButton<T> extends StatelessWidget {
  final bool enabled;
  final PopupMenuItemSelected<T>? onSelected;
  final PopupMenuItemBuilder<T> itemBuilder;
  final Widget? child;
  final EdgeInsetsGeometry? padding;

  const AppOverflowMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.enabled = true,
    this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      enabled: enabled,
      onSelected: onSelected,
      color: AppColors.surface,
      position: PopupMenuPosition.under,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      padding: padding ?? EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.border),
      ),
      itemBuilder: itemBuilder,
      child: child ??
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(Icons.more_horiz,
                size: 16, color: AppColors.textMuted),
          ),
    );
  }
}

class AppSectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const AppSectionCard({
    super.key,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      color: AppColors.backgroundElevated,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: AppTypography.bodyM,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class AppSelectionChip extends StatelessWidget {
  final String label;
  final bool active;

  const AppSelectionChip({
    super.key,
    required this.label,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? AppColors.chipActiveBg : AppColors.background,
        border: Border.all(
          color: active ? AppColors.chipActiveBorder : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? AppColors.chipActiveText : AppColors.chipInactiveText,
          fontSize: AppTypography.bodyS,
        ),
      ),
    );
  }
}

class AppSegmentedOption<T> {
  final T value;
  final String label;

  const AppSegmentedOption({
    required this.value,
    required this.label,
  });
}

class AppSegmentedControl<T> extends StatelessWidget {
  final List<AppSegmentedOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double? maxWidth;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry itemPadding;
  final double borderRadius;
  final double itemRadius;
  final double fontSize;

  const AppSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.maxWidth,
    this.padding = const EdgeInsets.all(4),
    this.itemPadding = const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    this.borderRadius = 18,
    this.itemRadius = 16,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: options
            .map(
              (AppSegmentedOption<T> option) => Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => onChanged(option.value),
                    borderRadius: BorderRadius.circular(itemRadius),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      padding: itemPadding,
                      decoration: BoxDecoration(
                        color: option.value == value
                            ? AppColors.primary
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(itemRadius),
                      ),
                      child: Text(
                        option.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: option.value == value
                              ? AppColors.background
                              : AppColors.textSecondary,
                          fontSize: fontSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );

    if (maxWidth != null) {
      child = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: child,
      );
    }

    return child;
  }
}

class AppSelectOption<T> {
  final T value;
  final String label;

  const AppSelectOption({
    required this.value,
    required this.label,
  });
}

class AppOverlaySelect<T> extends StatefulWidget {
  final List<AppSelectOption<T>> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final String placeholder;
  final String? label;
  final bool enabled;
  final bool loading;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry padding;
  final Color backgroundColor;
  final Color borderColor;
  final Color activeBorderColor;
  final double borderRadius;
  final double itemHeight;
  final double triggerHeight;
  final double? width;
  final bool Function(T optionValue, T? selectedValue)? isSelected;
  final Widget? Function(T? value, bool isOpen, bool loading)?
      triggerLeadingBuilder;
  final Widget? Function(AppSelectOption<T> option, bool isSelected)?
      itemLeadingBuilder;
  final Widget? Function(AppSelectOption<T> option, bool isSelected)?
      itemTrailingBuilder;
  final bool Function(AppSelectOption<T> option)? itemEnabledBuilder;
  final Widget? Function(
    AppSelectOption<T> option,
    bool isSelected,
    bool isEnabled,
  )? itemLabelBuilder;
  final bool Function(AppSelectOption<T> option)? closeOnSelectBuilder;

  const AppOverlaySelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.placeholder,
    this.label,
    this.enabled = true,
    this.loading = false,
    this.margin,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    this.backgroundColor = const Color(0xFF161B22),
    this.borderColor = AppColors.border,
    this.activeBorderColor = AppColors.primary,
    this.borderRadius = 6,
    this.itemHeight = 40,
    this.triggerHeight = 46,
    this.width,
    this.isSelected,
    this.triggerLeadingBuilder,
    this.itemLeadingBuilder,
    this.itemTrailingBuilder,
    this.itemEnabledBuilder,
    this.itemLabelBuilder,
    this.closeOnSelectBuilder,
  });

  @override
  State<AppOverlaySelect<T>> createState() => _AppOverlaySelectState<T>();
}

class _AppOverlaySelectState<T> extends State<AppOverlaySelect<T>> {
  final GlobalKey _triggerKey = GlobalKey();
  OverlayEntry? _overlay;
  T? _hoveredOption;

  bool get _isOpen => _overlay != null;

  bool _matches(T optionValue, T? selectedValue) {
    final matcher = widget.isSelected;
    if (matcher != null) {
      return matcher(optionValue, selectedValue);
    }
    return optionValue == selectedValue;
  }

  AppSelectOption<T>? get _selectedOption {
    for (final option in widget.options) {
      if (_matches(option.value, widget.value)) {
        return option;
      }
    }
    return null;
  }

  void _toggle() {
    if (!widget.enabled) {
      return;
    }
    if (_overlay != null) {
      _close();
      return;
    }
    final RenderBox? box =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final Offset position = box.localToGlobal(Offset.zero);
    _overlay = OverlayEntry(
      builder: (_) => _buildOverlay(position, box.size),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() {});
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
    _hoveredOption = null;
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AppOverlaySelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isOpen) {
      _overlay?.markNeedsBuild();
    }
  }

  bool _isHovered(T optionValue) {
    final T? current = _hoveredOption;
    if (current == null) {
      return false;
    }
    return _matches(optionValue, current);
  }

  Widget _buildOverlay(Offset position, Size triggerSize) {
    final double maxHeight = (widget.options.length * widget.itemHeight + 8)
        .clamp(80, 300)
        .toDouble();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _close,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: position.dx,
            top: position.dy + triggerSize.height + 4,
            width: triggerSize.width,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  border: Border.all(color: AppColors.border),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  children: widget.options.map((AppSelectOption<T> option) {
                    final bool selected = _matches(option.value, widget.value);
                    final bool hovered = _isHovered(option.value);
                    final bool enabled =
                        widget.itemEnabledBuilder?.call(option) ?? true;
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      mouseCursor: enabled
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      onHover: (bool value) {
                        if (!enabled) {
                          return;
                        }
                        if (value) {
                          _hoveredOption = option.value;
                        } else if (_isHovered(option.value)) {
                          _hoveredOption = null;
                        }
                        _overlay?.markNeedsBuild();
                      },
                      hoverColor: Colors.transparent,
                      focusColor: Colors.transparent,
                      splashColor: const Color(0x2258A6FF),
                      highlightColor: const Color(0x2258A6FF),
                      onTap: enabled
                          ? () {
                              widget.onChanged(option.value);
                              final bool close =
                                  widget.closeOnSelectBuilder?.call(option) ??
                                      true;
                              if (close) {
                                _close();
                              } else {
                                _overlay?.markNeedsBuild();
                              }
                            }
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          curve: Curves.easeOutCubic,
                          height: widget.itemHeight,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(0xFF21262D)
                                : (hovered
                                    ? const Color(0x2858A6FF)
                                    : Colors.transparent),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: selected
                                  ? AppColors.border
                                  : (hovered
                                      ? const Color(0x6658A6FF)
                                      : Colors.transparent),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              if (widget.itemLeadingBuilder !=
                                  null) ...<Widget>[
                                widget.itemLeadingBuilder!(option, selected) ??
                                    const SizedBox.shrink(),
                                const SizedBox(width: 8),
                              ],
                              Expanded(
                                child: widget.itemLabelBuilder?.call(
                                      option,
                                      selected,
                                      enabled,
                                    ) ??
                                    Text(
                                      option.label,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: !enabled
                                            ? const Color(0xFF8B949E)
                                            : (selected
                                                ? Colors.white
                                                : const Color(0xFFCDD5DF)),
                                        fontSize: AppTypography.bodyM,
                                      ),
                                    ),
                              ),
                              if (widget.itemTrailingBuilder != null)
                                widget.itemTrailingBuilder!(option, selected) ??
                                    const SizedBox.shrink(),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSelectOption<T>? selected = _selectedOption;
    final Widget? leading = widget.triggerLeadingBuilder
        ?.call(widget.value, _isOpen, widget.loading);
    final Widget trigger = GestureDetector(
      key: _triggerKey,
      onTap: _toggle,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: Container(
          width: widget.width,
          margin: widget.margin,
          constraints: BoxConstraints(minHeight: widget.triggerHeight),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _isOpen ? widget.activeBorderColor : widget.borderColor,
            ),
          ),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading,
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  selected?.label ?? widget.placeholder,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected != null
                        ? Colors.white
                        : const Color(0xFF8B949E),
                    fontSize: AppTypography.bodyM,
                    fontWeight:
                        selected != null ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
              ),
              Icon(
                _isOpen ? Icons.expand_less : Icons.expand_more,
                size: 14,
                color: const Color(0xFF8B949E),
              ),
            ],
          ),
        ),
      ),
    );
    if ((widget.label ?? '').isEmpty) {
      return trigger;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.label!,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: AppTypography.bodyS,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        trigger,
      ],
    );
  }
}

class AppPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: padding,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: AppTypography.titleM,
              fontWeight: FontWeight.w600,
            ),
          ),
          if ((subtitle ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(width: 12),
            Text(
              subtitle!,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: AppTypography.bodyM,
              ),
            ),
          ],
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class AppHeaderSearchRefresh extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final String hintText;
  final VoidCallback? onRefresh;
  final double expandedWidth;
  final AppHeaderSearchRefreshController? controller;

  const AppHeaderSearchRefresh({
    super.key,
    required this.value,
    required this.onChanged,
    this.hintText = '搜索',
    this.onRefresh,
    this.expandedWidth = 220,
    this.controller,
  });

  @override
  State<AppHeaderSearchRefresh> createState() => _AppHeaderSearchRefreshState();
}

class _AppHeaderSearchRefreshState extends State<AppHeaderSearchRefresh> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChanged);
    _expanded = widget.value.trim().isNotEmpty;
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant AppHeaderSearchRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
    if (widget.value.trim().isNotEmpty && !_expanded) {
      _expanded = true;
    }
    if (widget.value.trim().isEmpty && !_focusNode.hasFocus && _expanded) {
      _expanded = false;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _focusNode.removeListener(_handleFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_focusNode.hasFocus) {
      return;
    }
    if (_controller.text.trim().isNotEmpty || !_expanded) {
      return;
    }
    if (mounted) {
      setState(() => _expanded = false);
    }
  }

  void _expandAndFocus() {
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        _controller.selection =
            TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
      }
    });
  }

  void _collapseAndClear() {
    _focusNode.unfocus();
    _controller.clear();
    widget.onChanged('');
    setState(() => _expanded = false);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: _expanded ? widget.expandedWidth : 36,
            height: 36,
            child: _expanded
                ? TextField(
                    key: const ValueKey<String>('expanded_search'),
                    controller: _controller,
                    focusNode: _focusNode,
                    onChanged: widget.onChanged,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppTypography.bodyM,
                    ),
                    decoration: AppInputDecorations.outlined(
                      hintText: widget.hintText,
                      fillColor: AppColors.surface,
                      radius: 8,
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 16,
                        color: AppColors.textMuted,
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _collapseAndClear,
                              borderRadius: BorderRadius.circular(8),
                              child: const SizedBox(
                                width: 24,
                                height: 24,
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : OutlinedButton(
                    key: const ValueKey<String>('collapsed_search'),
                    onPressed: _expandAndFocus,
                    style: AppButtonStyles.outlined(
                      background: AppColors.surface,
                      minimumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                      radius: 8,
                    ),
                    child: const Icon(
                      Icons.search,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          height: 36,
          child: OutlinedButton(
            onPressed: widget.onRefresh,
            style: AppButtonStyles.outlined(
              background: AppColors.surface,
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              radius: 8,
            ),
            child: const Icon(
              Icons.refresh,
              size: 16,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

class AppHeaderSearchRefreshController {
  _AppHeaderSearchRefreshState? _state;

  void _attach(_AppHeaderSearchRefreshState state) {
    _state = state;
  }

  void _detach(_AppHeaderSearchRefreshState state) {
    if (_state == state) {
      _state = null;
    }
  }

  void focus() {
    _state?._expandAndFocus();
  }

  void clear() {
    _state?._collapseAndClear();
  }
}

class AppPanelHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  const AppPanelHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.35),
              ),
            ),
            child: Icon(icon, size: 15, color: AppColors.primaryGlow),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppTypography.bodyL,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if ((subtitle ?? '').isNotEmpty)
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: AppTypography.bodyS,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class AppInfoBanner extends StatelessWidget {
  final String message;
  final IconData icon;
  final AppTone tone;

  const AppInfoBanner({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.tone = AppTone.info,
  });

  @override
  Widget build(BuildContext context) {
    final _AppTonePalette palette = _paletteForTone(tone);
    return AppSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      color: AppColors.backgroundElevated,
      borderColor: palette.border,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: palette.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppTypography.bodyS,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AppStateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final AppTone tone;

  const AppStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.tone = AppTone.info,
  });

  @override
  Widget build(BuildContext context) {
    final _AppTonePalette palette = _paletteForTone(tone);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: AppSurface(
          padding: const EdgeInsets.all(22),
          color: AppColors.backgroundElevated,
          borderColor: palette.border,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: palette.foreground, size: 28),
              const SizedBox(height: 14),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: AppTypography.titleM,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: AppTypography.bodyM,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppBusyOverlay extends StatelessWidget {
  final bool visible;
  final String? label;

  const AppBusyOverlay({
    super.key,
    required this.visible,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: visible ? 1 : 0,
        child: Container(
          color: Colors.black.withValues(alpha: 0.16),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(color: AppColors.primary),
              if ((label ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  label!,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppTypography.bodyS,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AppDialogFrame extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget> actions;
  final AppDialogSize size;
  final double? maxWidth;
  final double? maxHeight;
  final Widget? trailing;
  final bool showCloseButton;

  const AppDialogFrame({
    super.key,
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.size = AppDialogSize.medium,
    this.maxWidth,
    this.maxHeight,
    this.trailing,
    this.showCloseButton = true,
  });

  double _maxWidthForSize() {
    switch (size) {
      case AppDialogSize.compact:
        return 460;
      case AppDialogSize.medium:
        return 560;
      case AppDialogSize.large:
        return 760;
      case AppDialogSize.xlarge:
        return 860;
    }
  }

  bool _isCancelAction(Widget widget) {
    if (widget is AppSecondaryButton) {
      return widget.label.trim() == '取消';
    }
    Widget? child;
    if (widget is TextButton) {
      child = widget.child;
    } else if (widget is ElevatedButton) {
      child = widget.child;
    } else if (widget is OutlinedButton) {
      child = widget.child;
    }
    if (child is Text) {
      return (child.data ?? '').trim() == '取消';
    }
    return false;
  }

  bool _isHorizontalSpacer(Widget widget) {
    return widget is SizedBox && (widget.width ?? 0) > 0;
  }

  List<Widget> _normalizeActions() {
    if (!showCloseButton || actions.isEmpty) {
      return actions;
    }
    final List<Widget> filtered = actions
        .where((Widget widget) => !_isCancelAction(widget))
        .toList(growable: true);
    while (filtered.isNotEmpty && _isHorizontalSpacer(filtered.first)) {
      filtered.removeAt(0);
    }
    while (filtered.isNotEmpty && _isHorizontalSpacer(filtered.last)) {
      filtered.removeLast();
    }
    final List<Widget> compact = <Widget>[];
    var prevSpacer = false;
    for (final Widget widget in filtered) {
      final bool spacer = _isHorizontalSpacer(widget);
      if (spacer && (prevSpacer || compact.isEmpty)) {
        continue;
      }
      compact.add(widget);
      prevSpacer = spacer;
    }
    return compact;
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> normalizedActions = _normalizeActions();
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth ?? _maxWidthForSize(),
              maxHeight: maxHeight ?? MediaQuery.sizeOf(context).height - 56,
            ),
            child: AppSurface(
              radius: 14,
              color: AppColors.surface,
              borderColor: AppColors.border,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: AppTypography.titleL,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (trailing != null) trailing!,
                      if (trailing != null && showCloseButton)
                        const SizedBox(width: 8),
                      if (showCloseButton)
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          splashRadius: 18,
                          icon: const Icon(
                            Icons.close,
                            size: 18,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Flexible(child: child),
                  if (normalizedActions.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: normalizedActions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final AppTone tone;

  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.tone = AppTone.danger,
  });

  @override
  Widget build(BuildContext context) {
    return AppDialogFrame(
      title: title,
      size: AppDialogSize.compact,
      child: Text(
        message,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: AppTypography.bodyM,
          height: 1.5,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        const SizedBox(width: 10),
        ElevatedButton(
          style: AppButtonStyles.filled(
            background:
                tone == AppTone.danger ? AppColors.danger : AppColors.success,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
