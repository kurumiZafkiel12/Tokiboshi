import 'dart:async';
import 'dart:ffi';
import 'dart:io';

/// The elevated child waits for its parent to exit before attempting the
/// single-instance lock, reading configuration, or binding core ports.
Future<bool> waitForParentExit(int parentPid, {
  Duration timeout = const Duration(seconds: 30),
  Duration interval = const Duration(milliseconds: 100),
  int Function()? probe,
}) async {
  if (parentPid <= 0 || parentPid == pid) return false;
  Pointer<Void>? handle;
  int Function(Pointer<Void>)? close;
  late int Function() status;
  if (probe != null) {
    status = probe;
  } else {
    if (!Platform.isWindows) return false;
    final lib = DynamicLibrary.open('kernel32.dll');
    final open = lib.lookupFunction<Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('OpenProcess');
    final wait = lib.lookupFunction<Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)>('WaitForSingleObject');
    final error = lib.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
    close = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');
    handle = open(0x00100000, 0, parentPid); // SYNCHRONIZE only.
    if (handle.address == 0) return error() == 87; // Parent already exited.
    final processHandle = handle;
    status = () => wait(processHandle, 0);
  }
  final clock = Stopwatch()..start();
  try {
    while (true) {
      final value = status();
      if (value == 0) return true; // WAIT_OBJECT_0.
      if (value != 258 || clock.elapsed >= timeout) return false;
      await Future<void>.delayed(interval);
    }
  } finally {
    if (handle != null && handle.address != 0) close?.call(handle);
  }
}
