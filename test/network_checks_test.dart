// Ported fixtures from the user's Hotaru project (network_diagnostics_test).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/network_checks.dart';

Uint8List response(Uint8List transaction, InternetAddress address, int port) {
  final raw = address.rawAddress;
  final packet = Uint8List(28 + raw.length);
  final bytes = ByteData.sublistView(packet);
  bytes.setUint16(0, 0x0101);
  bytes.setUint16(2, packet.length - 20);
  bytes.setUint32(4, 0x2112a442);
  packet.setRange(8, 20, transaction);
  bytes.setUint16(20, 0x0020);
  bytes.setUint16(22, raw.length + 4);
  packet[25] = raw.length == 4 ? 1 : 2;
  bytes.setUint16(26, port ^ 0x2112);
  final mask = Uint8List(16);
  ByteData.sublistView(mask).setUint32(0, 0x2112a442);
  mask.setRange(4, 16, transaction);
  for (var i = 0; i < raw.length; i++) {
    packet[28 + i] = raw[i] ^ mask[i];
  }
  return packet;
}

void main() {
  final transaction = Uint8List.fromList(List.generate(12, (i) => i + 1));

  test('decodes transaction-bound IPv4 and IPv6 XOR mapped addresses', () {
    for (final ip in ['8.8.4.4', '2606:4700:4700::1111']) {
      final parsed = parseStunResponse(
        response(transaction, InternetAddress(ip), 49153),
        transaction,
      );
      expect(parsed!.address.address, InternetAddress(ip).address);
      expect(parsed.port, 49153);
    }
  });

  test('rejects a wrong transaction, non-binding response and truncated attributes',
      () {
    final packet = response(transaction, InternetAddress('8.8.8.8'), 50000);
    expect(parseStunResponse(packet, Uint8List(12)), isNull);
    expect(
        parseStunResponse(packet.sublist(0, packet.length - 1), transaction),
        isNull);
    final wrongType = Uint8List.fromList(packet)..[0] = 0x11;
    expect(parseStunResponse(wrongType, transaction), isNull);
    final wrongLength = Uint8List.fromList(packet)..[23] = 40;
    expect(parseStunResponse(wrongLength, transaction), isNull);
  });

  test('does not classify local, fake-IP, documentation or shared addresses as public',
      () {
    for (final ip in [
      '0.0.0.0',
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '192.168.0.1',
      '100.64.0.1',
      '198.18.0.1',
      '192.0.2.1',
      '203.0.113.4',
      '::',
      '::1',
      'fc00::1',
      'fe80::1',
      '2001:db8::1',
      '::ffff:192.168.1.1',
    ]) {
      expect(isPublicProbeAddress(InternetAddress(ip)), isFalse, reason: ip);
    }
    for (final ip in ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) {
      expect(isPublicProbeAddress(InternetAddress(ip)), isTrue, reason: ip);
    }
  });

  test('proxy residual requires a stopped core and an active setting', () {
    // Kernel running: nothing counts as residual regardless of registry.
    expect(
        proxyResidual(
                coreRunning: true,
                proxyServer: '127.0.0.1:7891',
                pac: null)
            .residual,
        isFalse);
    // Stopped core + active proxy value = residual.
    expect(
        proxyResidual(
                coreRunning: false,
                proxyServer: '127.0.0.1:7891',
                pac: null)
            .residual,
        isTrue);
    // Stopped core + PAC only = residual.
    expect(
        proxyResidual(
                coreRunning: false, proxyServer: null, pac: 'http://pac')
            .residual,
        isTrue);
    // Nothing set = clean.
    expect(
        proxyResidual(
                coreRunning: false, proxyServer: null, pac: null)
            .residual,
        isFalse);
  });
}
