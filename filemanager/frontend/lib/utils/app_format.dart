class AppFormat {
  static const List<String> _byteUnits = <String>[
    'B',
    'KB',
    'MB',
    'GB',
    'TB',
    'PB',
  ];

  const AppFormat._();

  static String bytes(num value) {
    if (value <= 0) {
      return '0 B';
    }

    double scaled = value.toDouble();
    int unitIndex = 0;
    while (scaled >= 1024 && unitIndex < _byteUnits.length - 1) {
      scaled /= 1024;
      unitIndex += 1;
    }

    return '${_formatNumber(scaled)} ${_byteUnits[unitIndex]}';
  }

  static String bytesPerSecond(num value) {
    return '${bytes(value)}/s';
  }

  static String _formatNumber(double value) {
    if (value >= 100 || value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }
}
