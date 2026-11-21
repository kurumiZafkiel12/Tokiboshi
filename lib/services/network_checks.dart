/// Network checks & repair (toolbox), ported from the user's own Hotaru
/// project (apps/hotaru/lib/common/network_diagnostics.dart): a minimal
/// RFC 5389 STUN client for discovering the physical egress IP, plus
/// Windows system-proxy residual detection/repair helpers.
///
/// 语义（与工具箱的"检测与修复"卡对应）：
/// - 经代理出口 IP：HTTP 查询走 mixed 入站（调用方注入 client）。
/// - 物理出口 IP：STUN UDP 直接出系统网络栈。mixed/system-proxy 模式下
///   UDP 不经代理，反映真实物理出口；TUN 模式下 UDP 被接管，二者一致
///   属正常（UI 需按 running/enableTun 说明）。
/// - 系统代理残留：内核未运行时 ProxyEnable=1 或 AutoConfigURL 残留 →
///   提供一键清理（reg.exe，用户级，无管理员要求）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _stunCookie = 0x2112a442;

class StunEndpoint {
  const StunEndpoint(this.address, this.port);

  final InternetAddress address;
  final int port;

  @override
  String toString() => '${address.address}:$port';
}

StunEndpoint? parseStunResponse(Uint8List packet, Uint8List transaction) {
  if (packet.length < 20 || transaction.length != 12) return null;
  final bytes = ByteData.sublistView(packet);
  if (bytes.getUint16(0) != 0x0101 || bytes.getUint32(4) != _stunCookie) {
    return null;
  }
  final length = bytes.getUint16(2);
  if (length % 4 != 0 || length + 20 > packet.length) return null;
  for (var i = 0; i < 12; i++) {
    if (packet[i + 8] != transaction[i]) return null;
  }
  StunEndpoint? mapped;
  for (var at = 20; at + 4 <= length + 20;) {
    final type = bytes.getUint16(at);
    final size = bytes.getUint16(at + 2);
    final start = at + 4;
    if (start + size > length + 20) return null;
    if ((type == 0x0020 || type == 0x0001) && size >= 8) {
      final family = packet[start + 1];
      final addressLength = family == 1
          ? 4
          : family == 2
              ? 16
              : 0;
      if (addressLength != 0 && size == addressLength + 4) {
        final mask = Uint8List(16);
        ByteData.sublistView(mask).setUint32(0, _stunCookie);
        mask.setRange(4, 16, transaction);
        final raw = Uint8List(addressLength);
        for (var i = 0; i < addressLength; i++) {
          raw[i] = packet[start + 4 + i] ^ (type == 0x0020 ? mask[i] : 0);
        }
        final endpoint = StunEndpoint(
          InternetAddress.fromRawAddress(raw),
          bytes.getUint16(start + 2) ^ (type == 0x0020 ? _stunCookie >> 16 : 0),
        );
        if (type == 0x0020) return endpoint;
        mapped = endpoint;
      }
    }
    at = start + ((size + 3) & ~3);
  }
  return mapped;
}

bool isPublicProbeAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  if (bytes.length == 4) {
    return bytes[0] != 0 &&
        bytes[0] != 10 &&
        bytes[0] != 127 &&
        !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
        !(bytes[0] == 192 && bytes[1] == 168) &&
        !(bytes[0] == 192 &&
            bytes[1] == 0 &&
            (bytes[2] == 0 || bytes[2] == 2)) &&
        !(bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) &&
        !(bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) &&
        !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) &&
        !(bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) &&
        bytes[0] < 224;
  }
  if (bytes.take(10).every((value) => value == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    return isPublicProbeAddress(
      InternetAddress.fromRawAddress(Uint8List.fromList(bytes.sublist(12))),
    );
  }
  return (bytes[0] & 0xe0) == 0x20 &&
      !(bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8);
}

class StunProbe {
  RawDatagramSocket? _socket;
  Completer<StunEndpoint>? _pending;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const SocketException('cancelled'));
    }
    _socket?.close();
  }

  Future<StunEndpoint> run(
    String host,
    int port, {
    InternetAddressType family = InternetAddressType.IPv4,
  }) async {
    final addresses =
        await InternetAddress.lookup(host, type: family).timeout(
      const Duration(seconds: 5),
    );
    if (_cancelled) throw const SocketException('cancelled');
    if (addresses.isEmpty) {
      throw const SocketException('no STUN server address');
    }
    final server = addresses.first;
    final socket = await RawDatagramSocket.bind(
      server.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    _socket = socket;
    if (_cancelled) {
      socket.close();
      throw const SocketException('cancelled');
    }
    final transaction =
        Uint8List.fromList(List.generate(12, (_) => Random.secure().nextInt(256)));
    final request = Uint8List(20);
    final bytes = ByteData.sublistView(request);
    bytes.setUint16(0, 0x0001);
    bytes.setUint32(4, _stunCookie);
    request.setRange(8, 20, transaction);
    final completer = Completer<StunEndpoint>();
    _pending = completer;
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final reply = datagram!;
        if (reply.address.address != server.address || reply.port != port) {
          continue;
        }
        final endpoint = parseStunResponse(reply.data, transaction);
        if (endpoint != null && !completer.isCompleted) {
          completer.complete(endpoint);
        }
      }
    }, onError: (Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    });
    final retry =
        Timer.periodic(const Duration(milliseconds: 750), (_) => socket.send(request, server, port));
    socket.send(request, server, port);
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      retry.cancel();
      await subscription.cancel();
      socket.close();
      _socket = null;
      _pending = null;
    }
  }
}

/// 公开 STUN 服务器，顺序尝试。
const stunServers = [
  ('stun.l.google.com', 19302),
  ('stun.cloudflare.com', 3478),
];

/// 物理出口 IP（STUN）。任一服务器成功即返回。
Future<InternetAddress> probePhysicalIp() async {
  Object? lastError;
  for (final (host, port) in stunServers) {
    final probe = StunProbe();
    try {
      final endpoint = await probe.run(host, port);
      if (isPublicProbeAddress(endpoint.address)) return endpoint.address;
      lastError = SocketException('STUN 返回非公网地址：${endpoint.address}');
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError ?? const SocketException('STUN 探测失败');
}

class ExitIpInfo {
  const ExitIpInfo(this.ip, this.asn, this.country);
  final String ip, asn, country;
}

/// 经指定 client（走代理或直连，由调用方决定）查询出口归属。
Future<ExitIpInfo?> queryExitIp(HttpClient client) async {
  try {
    final req = await client
        .getUrl(Uri.parse('http://ip-api.com/json/?fields=query,as,country&lang=zh-CN'))
        .timeout(const Duration(seconds: 8));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    final body = await resp.transform(utf8.decoder).join();
    final v = jsonDecode(body) as Map;
    final ip = (v['query'] ?? '') as String;
    if (ip.isEmpty) return null;
    return ExitIpInfo(
        ip, (v['as'] ?? '') as String, (v['country'] ?? '') as String);
  } catch (_) {
    return null;
  }
}

/// Windows 系统代理残留：ProxyEnable=1 或存在 AutoConfigURL。
/// [proxyServer] 来自 SystemProxy.readProxyServer（null = 未设置）。
/// [pac] = AutoConfigURL 值（可能为空串/未设置）。
({bool residual, String? server, String? pac}) proxyResidual(
    {required bool coreRunning, required String? proxyServer, required String? pac}) {
  final serverSet = proxyServer != null && proxyServer.isNotEmpty;
  final pacSet = pac != null && pac.isNotEmpty;
  final residual = serverSet || pacSet;
  return (
    residual: residual && !coreRunning,
    server: proxyServer,
    pac: pac,
  );
}

/// 读 AutoConfigURL（PAC）。失败/未设置返回 null。
Future<String?> readAutoConfigUrl() async {
  if (!Platform.isWindows) return null;
  try {
    final result = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      '/v',
      'AutoConfigURL',
    ]);
    if (result.exitCode != 0) return null;
    final match = RegExp(r'REG_SZ\s+(\S+)', caseSensitive: false)
        .firstMatch('${result.stdout}');
    return match?.group(1);
  } catch (_) {
    return null;
  }
}

/// 一键清理残留：ProxyEnable=0 + 删除 AutoConfigURL（如存在）。
/// 返回是否全部成功。参考 Hotaru clearWindowsPac。
Future<bool> clearProxyResidual() async {
  if (!Platform.isWindows) return true;
  final results = <bool>[];
  final disable = await Process.run('reg', [
    'add',
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f',
  ]);
  results.add(disable.exitCode == 0);
  final pac = await Process.run('reg', [
    'delete',
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    '/v', 'AutoConfigURL', '/f',
  ]);
  // AutoConfigURL 可能本来就不存在：非零也可接受，只要不是权限类失败。
  results.add(pac.exitCode == 0 || '${pac.stderr}'.contains('unable to find'));
  return results.every((ok) => ok);
}
