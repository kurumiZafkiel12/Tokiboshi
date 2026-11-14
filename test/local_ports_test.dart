import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/local_ports.dart';

void main() {
  test('occupied listener remains alive while client chooses another port', () async {
    final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(occupied.close);
    final selected = await findAvailablePort(occupied.port, {});
    expect(selected, isNot(occupied.port));
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, selected);
    await probe.close();
    final connection = await Socket.connect(InternetAddress.loopbackIPv4, occupied.port);
    connection.destroy();
  });
}
