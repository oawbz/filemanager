import 'dart:async';
import 'package:web/web.dart' as web;

Future<web.File> getFileFromEntry(web.FileSystemFileEntry entry) async {
  // For dart2js, this will use dart:html via conditional import
  // This is a stub - the actual implementation uses dart:html
  throw UnsupportedError('Use dart:html implementation');
}

Future<List<web.FileSystemEntry>> readEntriesFromReader(
    web.FileSystemDirectoryReader reader) async {
  // For dart2js, this will use dart:html via conditional import
  // This is a stub - the actual implementation uses dart:html
  throw UnsupportedError('Use dart:html implementation');
}
