import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Local PGN renames never overwrite an existing file, even if another process
/// creates the destination after validation. File.rename alone cannot promise it.
void moveLocalPgnWithoutReplacing(String source, String destination) {
  if (Platform.isWindows) {
    final move = DynamicLibrary.open('kernel32.dll').lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('MoveFileW');
    final from = source.toNativeUtf16();
    final to = destination.toNativeUtf16();
    try {
      if (move(from, to) == 0) {
        throw FileSystemException(
          'Cannot rename database; destination may exist or file is in use.',
          destination,
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
    return;
  }
  // Same-directory regular files: link is exclusive, unlike POSIX rename.
  // If unlink fails, remove only the link we just created and retain the source.
  final libc = DynamicLibrary.process();
  final link = libc.lookupFunction<
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
    int Function(Pointer<Utf8>, Pointer<Utf8>)
  >('link');
  final unlink = libc.lookupFunction<
    Int32 Function(Pointer<Utf8>),
    int Function(Pointer<Utf8>)
  >('unlink');
  final from = source.toNativeUtf8();
  final to = destination.toNativeUtf8();
  try {
    if (link(from, to) != 0) {
      throw FileSystemException(
        'Cannot rename database; destination may exist.',
        destination,
      );
    }
    if (unlink(from) != 0) {
      unlink(to);
      throw FileSystemException('Cannot remove old database name.', source);
    }
  } finally {
    calloc.free(from);
    calloc.free(to);
  }
}
