import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

class ImportedFile {
  const ImportedFile(this.name, this.path, this.text);
  final String name, path, text;
}

class ImportIo {
  const ImportIo();
  Future<ImportedFile?> readConfigFile() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
          label: '代理配置 / 订阅',
          extensions: ['yaml', 'yml', 'json', 'txt', 'conf', 'config']),
      const XTypeGroup(label: '所有文件')
    ]);
    if (f == null) return null;
    if (await f.length() > 8 * 1024 * 1024)
      throw const FormatException('配置文件超过 8 MiB');
    final text = await f.readAsString();
    return ImportedFile(f.name, f.path, text);
  }

  Future<String?> readQrFile() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
          label: '二维码图片',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'])
    ]);
    if (f == null) return null;
    if (await f.length() > 20 * 1024 * 1024)
      throw const FormatException('二维码图片超过 20 MiB');
    return await compute(decodeQrImage, await f.readAsBytes());
  }

  Future<String?> readClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.trim().isNotEmpty) return text;
    return readClipboardQr();
  }

  Future<String?> readClipboardQr() async {
    if (!Platform.isWindows) throw const FormatException('此平台请从图片文件导入二维码');
    final dir = await Directory.systemTemp.createTemp('tokiboshi-qr-');
    try {
      final path = '${dir.path}${Platform.pathSeparator}clipboard.png';
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Sta',
        '-WindowStyle',
        'Hidden',
        '-Command',
        r'Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; if ([System.Windows.Forms.Clipboard]::ContainsImage()) { $image=[System.Windows.Forms.Clipboard]::GetImage(); try { $image.Save($env:TOKIBOSHI_QR_PATH,[System.Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() } } else { exit 2 }'
      ], environment: {
        'TOKIBOSHI_QR_PATH': path
      });
      if (result.exitCode == 2) return null;
      if (result.exitCode != 0) throw const FormatException('无法读取剪贴板图片');
      final f = File(path);
      if (await f.length() > 20 * 1024 * 1024)
        throw const FormatException('剪贴板图片过大');
      return await compute(decodeQrImage, await f.readAsBytes());
    } finally {
      await dir.delete(recursive: true);
    }
  }
}

/// Runs in an isolate, including image decoding/rotation and QR detection.
String decodeQrImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('图片格式无法读取');
  img.Image picture = decoded;
  if (picture.width * picture.height > 32 * 1024 * 1024)
    throw const FormatException('图片尺寸过大，请裁剪二维码区域');
  if (picture.width > 2400 || picture.height > 2400)
    picture = img.copyResize(picture,
        width: picture.width >= picture.height ? 2400 : null,
        height: picture.height > picture.width ? 2400 : null);
  final hints = DecodeHints()..put(DecodeHintType.tryHarder);
  for (var turn = 0; turn < 4; turn++) {
    final source = RGBLuminanceSource(
        picture.width,
        picture.height,
        picture
            .convert(numChannels: 4)
            .getBytes(order: img.ChannelOrder.bgra)
            .buffer
            .asInt32List());
    for (final luminance in [source, source.invert()]) {
      try {
        final text = QRCodeReader()
            .decode(BinaryBitmap(HybridBinarizer(luminance)), hints: hints)
            .text;
        if (text.trim().isNotEmpty) return text;
      } catch (_) {}
    }
    picture = img.copyRotate(picture, angle: 90);
  }
  throw const FormatException('未识别到二维码，请选清晰的单个二维码图片');
}
