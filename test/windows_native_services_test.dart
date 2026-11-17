import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/desktop_services.dart';
import 'package:tokiboshi/services/import_io.dart';
import 'import_services_test.dart' show qrFixture;

void main() {
  final native = Platform.isWindows &&
      Platform.environment['TOKIBOSHI_NATIVE_CHECKS'] == '1';
  test('native Windows current-user startup write/read/remove roundtrip',
      () async {
    // The ephemeral CI user must not have a pre-existing entry; never overwrite one.
    final probe = await Process.run(
        'reg', ['query', WindowsStartup.key, '/v', 'Tokiboshi']);
    expect(probe.exitCode, isNot(0), reason: 'isolated runner required');
    final service = WindowsStartup(
        executable: r'C:\Tokiboshi Synthetic Fixture\tokiboshi.exe');
    try {
      await service.setEnabled(true);
      expect(await service.isEnabled(), true);
    } finally {
      await service.setEnabled(false);
    }
    expect(await service.isEnabled(), false);
  }, skip: !native);
  test('native process scanner finds the running test executable', () async {
    final names = await runningProcessNames();
    final executable = Platform.resolvedExecutable.split(RegExp(r'[\\/]')).last;
    expect(names, isNotEmpty);
    expect(matchesDemandProcesses([executable], names), true);
  }, skip: !native);
  test('native Windows clipboard bitmap decodes a real QR image', () async {
    final directory =
        await Directory.systemTemp.createTemp('tokiboshi-native-qr-');
    const text = 'https://fixture.example/subscription?token=synthetic-only';
    final file = File('${directory.path}\\fixture.png');
    await file.writeAsBytes(qrFixture(text));
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Sta',
        '-WindowStyle',
        'Hidden',
        '-Command',
        r'Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $image=[System.Drawing.Image]::FromFile($env:TOKIBOSHI_NATIVE_PNG); try { [System.Windows.Forms.Clipboard]::SetImage($image) } finally { $image.Dispose() }'
      ], environment: {
        'TOKIBOSHI_NATIVE_PNG': file.path
      });
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(await const ImportIo().readClipboardQr(), text);
    } finally {
      await Process.run('powershell', [
        '-NoProfile',
        '-Sta',
        '-WindowStyle',
        'Hidden',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::Clear()'
      ]);
      await directory.delete(recursive: true);
    }
  }, skip: !native);
}
