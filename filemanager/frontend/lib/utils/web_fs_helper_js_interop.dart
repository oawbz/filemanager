import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

Future<web.File> getFileFromEntry(web.FileSystemFileEntry entry) {
  final completer = Completer<web.File>();
  entry.file(
    ((web.File file) {
      if (!completer.isCompleted) {
        completer.complete(file);
      }
    }).toJS,
  );
  return completer.future;
}

Future<List<web.FileSystemEntry>> readEntriesFromReader(
    web.FileSystemDirectoryReader reader) {
  final completer = Completer<List<web.FileSystemEntry>>();
  reader.readEntries(
    ((JSArray<web.FileSystemEntry> batch) {
      if (!completer.isCompleted) {
        completer.complete(batch.toDart);
      }
    }).toJS,
  );
  return completer.future;
}
