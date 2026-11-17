import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../bridge/core_bridge.dart';
import '../bridge/rust_core_bridge.dart';

const androidVpnChannel = MethodChannel('site.kurumizafkiel.tokiboshi/vpn');

/// Parsing/config conversion stay in Rust. Lifecycle belongs to Android VpnService.
class AndroidCoreBridge extends RustCoreBridge {
  AndroidCoreBridge({this.channel = androidVpnChannel});
  final MethodChannel channel;
  Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(
        await channel.invokeMapMethod<String, dynamic>('status') ?? {},
      );
  @override
  Future<void> startCore({
    required String singBoxPath,
    required String configPath,
  }) async {
    final accepted = await channel.invokeMethod<bool>('prepare');
    if (accepted != true) throw const FormatException('已取消 VPN 授权，未建立连接');
    await channel.invokeMethod<void>('start', {'configPath': configPath});
    try {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final current = await status();
        if (current['phase'] == 'running') return;
        if (current['phase'] == 'error')
          throw FormatException('${current['error'] ?? 'VPN 启动失败'}');
        if (current['phase'] == 'stopped' && i > 3)
          throw const FormatException('VPN 启动已取消');
      }
      throw TimeoutException('VPN 启动超时');
    } catch (_) {
      await channel.invokeMethod<void>('stop');
      rethrow;
    }
  }

  @override
  Future<void> stopCore() async {
    await channel.invokeMethod<void>('stop');
    for (var i = 0; i < 200; i++) {
      final current = await status();
      if ((current['phase'] == 'stopped' || current['phase'] == 'error') &&
          current['serviceAlive'] != true) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('VPN 尚未完全停止');
  }

  @override
  Future<bool> coreRunning() async => (await status())['running'] == true;
  @override
  Future<CoreStatus> coreStatus() async {
    final current = await status();
    return CoreStatus(
      running: current['running'] == true,
      lastExit: current['error'] as String?,
    );
  }

  @override
  Future<List<String>> coreLogs() async =>
      (await channel.invokeListMethod<String>('logs')) ?? [];
  @override
  Future<String> coreVersion(String binaryPath) async =>
      'sing-box ${await channel.invokeMethod<String>('version')}';
  @override
  Future<String> managedCorePath(String dataDir) async => 'libbox://1.14.4';
  @override
  Future<void> startEnsureCore(String dataDir) async {}
  @override
  Future<EnsureState> ensureCoreState() async =>
      const EnsureState(phase: 'done', version: '1.14.4');
  @override
  Future<String> buildConfig({
    required List<NodeSpec> nodes,
    int mixedPort = 7890,
    int clashApiPort = 9090,
    bool enableTun = true,
    bool blockAds = true,
    bool bypassCn = true,
    String dataDir = '',
    String? selectedName,
    String profileJson = '',
  }) async {
    final config = await super.buildConfig(
      nodes: nodes,
      mixedPort: mixedPort,
      clashApiPort: clashApiPort,
      enableTun: false,
      blockAds: blockAds,
      bypassCn: bypassCn,
      dataDir: dataDir,
      selectedName: selectedName,
      profileJson: profileJson,
    );
    return androidConfig(config);
  }
}

/// Android owns routes and the TUN descriptor; no Windows UI/resource downloads.
String androidConfig(String raw) {
  final config = jsonDecode(raw) as Map<String, dynamic>;
  config['inbounds'] = [
    ...(config['inbounds'] as List).where((v) => v['type'] != 'tun'),
    {
      'type': 'tun',
      'tag': 'tun-in',
      'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
      'mtu': 1500,
      'auto_route': true,
      'strict_route': true,
      'stack': 'gvisor',
      'dns_mode': 'hijack',
      'dns_address': ['172.19.0.2', 'fdfe:dcba:9876::2'],
    },
  ];
  final api = (config['experimental'] as Map?)?['clash_api'];
  if (api is Map) {
    api.remove('external_ui');
    api.remove('external_ui_download_url');
    api.remove('external_ui_download_detour');
  }
  final route = config['route'] as Map<String, dynamic>;
  route['rules'] = [
    {
      'inbound': ['tun-in'],
      'action': 'sniff',
    },
    {
      'protocol': ['dns'],
      'action': 'hijack-dns',
    },
    ...route['rules'] as List,
  ];
  return jsonEncode(config);
}
