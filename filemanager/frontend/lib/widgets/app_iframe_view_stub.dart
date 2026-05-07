import 'package:flutter/material.dart';

class AppIframeView extends StatelessWidget {
  final String src;

  const AppIframeView({super.key, required this.src});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '当前平台不支持内嵌控制台',
        style: TextStyle(color: Colors.white70),
      ),
    );
  }
}
