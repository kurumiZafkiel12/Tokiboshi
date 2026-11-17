import 'package:flutter/foundation.dart';
import '../services/import_io.dart';
import 'android_bridge.dart';

class AndroidImportIo extends ImportIo {
  const AndroidImportIo();
  @override
  Future<String?> readClipboardQr() async {
    final bytes =
        await androidVpnChannel.invokeMethod<Uint8List>('clipboardImage');
    if (bytes == null) return null;
    return compute(decodeQrImage, bytes);
  }
}
