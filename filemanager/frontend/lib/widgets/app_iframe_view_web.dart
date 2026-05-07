import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class AppIframeView extends StatefulWidget {
  final String src;

  const AppIframeView({super.key, required this.src});

  @override
  State<AppIframeView> createState() => _AppIframeViewState();
}

class _AppIframeViewState extends State<AppIframeView> {
  static int _nextId = 0;

  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    _viewType = 'spanel-iframe-view-${_nextId++}';
    _iframe = web.HTMLIFrameElement()
      ..src = widget.src
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000';
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int _) => _iframe,
    );
  }

  @override
  void didUpdateWidget(covariant AppIframeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      _iframe.src = widget.src;
    }
  }

  @override
  void dispose() {
    _iframe.src = 'about:blank';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
