import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/desktop_settings.dart';
import 'package:tokiboshi/services/desktop_services.dart';
import 'package:tokiboshi/services/store.dart';

void main() {
  test(
      'startup registration quotes paths and verifies actual state using only its value',
      () async {
    String? command;
    final calls = <List<String>>[];
    final startup = WindowsStartup(
        executable: r'C:\Synthetic App\時の星\tokiboshi.exe',
        runner: (exe, args) async {
          expect(exe, 'reg');
          calls.add(args);
          if (args.first == 'add') {
            command = args[args.indexOf('/d') + 1];
            return ProcessResult(1, 0, '', '');
          }
          if (args.first == 'delete') {
            command = null;
            return ProcessResult(1, 0, '', '');
          }
          return ProcessResult(1, command == null ? 1 : 0,
              command == null ? '' : 'Tokiboshi REG_SZ $command', '');
        });
    await startup.setEnabled(true);
    expect(command, '"C:\\Synthetic App\\時の星\\tokiboshi.exe" --autostart');
    expect(await startup.isEnabled(), true);
    await startup.setEnabled(false);
    expect(await startup.isEnabled(), false);
    expect(calls.every((a) => a.contains(WindowsStartup.key)), true);
  });
  test(
      'network settings scope proxy authentication and keep controller authenticated',
      () {
    final base = jsonEncode({
      'inbounds': [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 7890}
      ],
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:9090',
          'secret': 'synthetic-secret'
        }
      }
    });
    final updated = jsonDecode(applyNetworkSettings(
        base,
        const DesktopSettings(
            allowLan: true,
            remoteController: true,
            proxyAuth: true,
            proxyUser: 'test',
            proxyPassword: 'synthetic')));
    expect(updated['inbounds'][0]['listen'], '0.0.0.0');
    expect(updated['inbounds'][0]['users'][0]['password'], 'synthetic');
    expect(updated['experimental']['clash_api']['secret'], 'synthetic-secret');
    expect(updated['experimental']['clash_api']['external_controller'],
        '0.0.0.0:9090');
    expect(
        () =>
            applyNetworkSettings(base, const DesktopSettings(proxyAuth: true)),
        throwsFormatException);
    expect(
        () => applyNetworkSettings(base.replaceAll('synthetic-secret', ''),
            const DesktopSettings(remoteController: true)),
        throwsFormatException);
  });
  test(
      'settings and explicit node-only/local-source choice survive actual disk save/load',
      () async {
    final dir = await Directory.systemTemp.createTemp('tokiboshi-r2-settings-');
    try {
      final store = Store(File('${dir.path}/data.json'));
      await store.save(AppData(
          desktop: const DesktopSettings(
              autoRun: true,
              onDemand: true,
              processes: ['Code.exe'],
              userAgent: 'custom-agent',
              verifyTls: false),
          subscriptions: const [
            Subscription(
                id: 'fixture',
                name: 'local',
                url: '',
                localPath: 'synthetic.yaml',
                nodesOnly: true)
          ]));
      final restored = await store.load();
      expect(restored.desktop.autoRun, true);
      expect(restored.desktop.onDemand, true);
      expect(restored.desktop.verifyTls, false);
      expect(restored.desktop.userAgent, 'custom-agent');
      expect(restored.subscriptions.single.nodesOnly, true);
      expect(restored.subscriptions.single.localPath, 'synthetic.yaml');
      expect(restored.subscriptions.single.isRemote, false);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('release ordering and demand process matching are deterministic', () {
    expect(isNewerTag('v0.0.9-r2', 'v0.0.9'), true);
    expect(isNewerTag('v0.0.9', 'v0.0.9-r2'), false);
    expect(isNewerTag('v0.0.10', 'v0.0.9-r2'), true);
    expect(isNewerTag('v0.0.9-r2', 'v0.0.9-r2'), false);
    expect(matchesDemandProcesses(['Code.exe'], {'code', 'explorer'}), true);
    expect(matchesDemandProcesses(['other.exe'], {'code'}), false);
  });
}
