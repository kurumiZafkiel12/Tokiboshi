import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/store.dart';
import 'package:tokiboshi/services/system_proxy.dart';

void main() {
  test('store round-trips nodes and settings', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(File('${tmp.path}/sub/data.json'));
    await store.save(AppData(
      nodes: const [NodeInfo(name: 'n1', outboundJson: '{"type":"direct"}')],
      selectedIndex: 0,
      mixedPort: 1080,
      singBoxPath: 'C:\\tools\\sing-box.exe',
      autoConnect: false,
    ));
    final loaded = await store.load();
    expect(loaded.nodes, hasLength(1));
    expect(loaded.nodes.first.name, 'n1');
    expect(loaded.selected?.name, 'n1');
    expect(loaded.mixedPort, 1080);
    expect(loaded.autoConnect, isFalse);
    expect(loaded.singBoxPath, r'C:\tools\sing-box.exe');
  });

  test('missing file loads defaults', () async {
    final store = Store(File('/nonexistent-dir-xyz/data.json'));
    final loaded = await store.load();
    expect(loaded.nodes, isEmpty);
    expect(loaded.mixedPort, 7890);
    expect(loaded.autoConnect, isTrue);
  });

  test('store round-trips subscriptions and node sources', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store2');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(File('${tmp.path}/data.json'));
    await store.save(AppData(
      nodes: const [
        NodeInfo(name: 'sn', outboundJson: '{"type":"ss"}', source: 'sub-1'),
      ],
      subscriptions: const [
        Subscription(
          id: 'sub-1',
          name: 'MySub',
          url: 'https://example.com/sub',
          updatedAt: '2026-11-14T00:00:00.000',
        ),
      ],
      systemProxy: false,
    ));
    final loaded = await store.load();
    expect(loaded.nodes.single.source, 'sub-1');
    expect(loaded.subscriptions.single.name, 'MySub');
    expect(loaded.subscriptions.single.updatedAt, isNotNull);
    expect(loaded.systemProxy, isFalse);
  });

  test('v0.1 format loads with defaults', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store3');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/data.json');
    await file.writeAsString(
      '{"nodes":[{"name":"old","outboundJson":"{\\"type\\":\\"direct\\"}"}],'
      '"selectedIndex":0,"mixedPort":7890,"singBoxPath":""}',
    );
    final loaded = await Store(file).load();
    expect(loaded.nodes.single.name, 'old');
    expect(loaded.nodes.single.source, '');
    expect(loaded.subscriptions, isEmpty);
    expect(loaded.systemProxy, isTrue);
  });

  test('pre-runningAtExit data migrates autoConnect into runningAtExit',
      () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store7');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/data.json');
    // Old-format file: autoConnect on, no runningAtExit key at all.
    await file.writeAsString('{"nodes":[],"autoConnect":true,"mixedPort":7890}');
    final loaded = await Store(file).load();
    expect(loaded.runningAtExit, isTrue,
        reason: 'old autoConnect users must keep auto-start after upgrade');

    // New-format data keeps its explicit value.
    await file.writeAsString(
        '{"nodes":[],"autoConnect":true,"runningAtExit":false,"mixedPort":7890}');
    final fresh = await Store(file).load();
    expect(fresh.runningAtExit, isFalse);
  });

  test('save keeps a backup of the previous good copy', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store4');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/data.json');
    final store = Store(file);
    await store.save(AppData()..mixedPort = 7891);
    // Nothing existed before the first save, so there is no backup yet.
    expect(File('${file.path}.bak').existsSync(), isFalse);
    await store.save(AppData()..mixedPort = 7892);
    final bak =
        jsonDecode(await File('${file.path}.bak').readAsString()) as Map<String, dynamic>;
    expect(bak['mixedPort'], 7891);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('corrupt main file falls back to the backup', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store5');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/data.json');
    final store = Store(file);
    await store.save(AppData()..mixedPort = 7893);
    await store.save(AppData()..mixedPort = 7894);
    await file.writeAsString('{broken json');
    final restored = await store.load();
    expect(restored.mixedPort, 7893);
    // The fallback must repair the main copy, or the next save would
    // rotate the still-corrupt main into .bak and destroy the only
    // good copy (HF053-11 remainder).
    expect(jsonDecode(await file.readAsString())['mixedPort'], 7893);
    await store.save(AppData()..mixedPort = 7895);
    final bak = jsonDecode(
        await File('${file.path}.bak').readAsString()) as Map<String, dynamic>;
    expect(bak['mixedPort'], 7893, reason: 'backup must stay parseable');
    await file.writeAsString('{broken again');
    expect((await store.load()).mixedPort, 7893);
  });

  test('round-trips secret and cleanExit flags', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store6');
    addTearDown(() => tmp.delete(recursive: true));
    final store = Store(File('${tmp.path}/data.json'));
    await store.save(AppData()
      ..clashApiSecret = 'abcd'
      ..cleanExit = false
      ..runningAtExit = true);
    final loaded = await store.load();
    expect(loaded.clashApiSecret, 'abcd');
    expect(loaded.cleanExit, isFalse);
    expect(loaded.runningAtExit, isTrue);
  });

  test('generateClashSecret is 32 hex chars and differs across calls', () {
    final a = generateClashSecret();
    final b = generateClashSecret();
    expect(a, hasLength(32));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
    expect(a, isNot(b));
  });

  test('injectClashSecret adds the secret to a bare config', () {
    const config = '{"outbounds":[],"listen_port":7890}';
    final map =
        jsonDecode(injectClashSecret(config, 'sekret')) as Map<String, dynamic>;
    expect(map['experimental']['clash_api']['secret'], 'sekret');
    expect(map['listen_port'], 7890);
  });

  test('injectClashSecret overwrites an existing secret', () {
    const config =
        '{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}';
    final map =
        jsonDecode(injectClashSecret(config, 'new')) as Map<String, dynamic>;
    expect(map['experimental']['clash_api']['secret'], 'new');
    expect(map['experimental']['clash_api']['external_controller'],
        '127.0.0.1:9090');
  });

  test('isStaleProxy matches only our own loopback endpoints', () {
    expect(isStaleProxy('127.0.0.1:7890', 7890), isTrue);
    expect(isStaleProxy('localhost:7890', 7890), isTrue);
    expect(isStaleProxy(' 127.0.0.1:7890 ', 7890), isTrue);
    expect(isStaleProxy('127.0.0.1:7891', 7890), isFalse);
    expect(isStaleProxy('http://127.0.0.1:7890', 7890), isFalse);
    expect(isStaleProxy(null, 7890), isFalse);
  });

  test('parses real reg.exe ProxyServer output (HV001-02)', () {
    const sample = '\r\n'
        'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\r\n'
        '    ProxyServer    REG_SZ    127.0.0.1:7890\r\n'
        '\r\n';
    expect(parseProxyServerFromRegOutput(sample), '127.0.0.1:7890');
    // A missing value line yields null instead of garbage.
    expect(parseProxyServerFromRegOutput('The system was unable to find the specified registry key.'),
        isNull);
  });

  test('unhealthy main is quarantined, backup preserved (HF053-11)', () async {
    final tmp = await Directory.systemTemp.createTemp('tokiboshi-store8');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/data.json');
    final store = Store(file);
    await store.save(AppData()..mixedPort = 7911);
    await store.save(AppData()..mixedPort = 7912);
    // Simulate the repair-failure branch: main corrupt, no load()
    // repair happened (e.g. read-only main made the copy fail).
    await file.writeAsString('{corrupt-primary');
    // The next save must quarantine the bad main, NOT rotate it into
    // the good backup.
    await store.save(AppData()..mixedPort = 7913);
    final bak = jsonDecode(
        await File('${file.path}.bak').readAsString()) as Map<String, dynamic>;
    expect(bak['mixedPort'], 7911, reason: 'good backup must survive');
    expect(jsonDecode(await file.readAsString())['mixedPort'], 7913);
    // And the recovery chain still works after a second corruption.
    await file.writeAsString('{broken again');
    expect((await store.load()).mixedPort, 7911);
  });
}
