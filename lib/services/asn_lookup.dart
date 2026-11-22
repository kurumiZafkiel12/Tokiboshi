import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

bool isPublicAsnAddress(String value) {
  final ip = InternetAddress.tryParse(value);
  if (ip == null || ip.isLoopback || ip.isLinkLocal || ip.isMulticast)
    return false;
  final b = ip.rawAddress;
  if (b.length == 16) {
    return (b[0] & 0xe0) == 0x20 &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8);
  }
  return b[0] > 0 &&
      b[0] < 224 &&
      b[0] != 10 &&
      !(b[0] == 100 && b[1] >= 64 && b[1] < 128) &&
      !(b[0] == 172 && b[1] >= 16 && b[1] < 32) &&
      !(b[0] == 192 && (b[1] == 168 || b[1] == 0)) &&
      !(b[0] == 192 && b[1] == 0 && b[2] == 2) &&
      !(b[0] == 198 &&
          (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) &&
      !(b[0] == 203 && b[1] == 0 && b[2] == 113);
}

typedef AsnOrigin = (int number, String holder);

List<AsnOrigin> parseAsnOrigins(Object? response) {
  final data = response is Map ? response['data'] : null;
  final rows = data is Map ? data['asns'] : null;
  if (rows is! List) return const [];
  return [
    for (final row in rows.whereType<Map>())
      if (row['asn'] is int && (row['asn'] as int) > 0)
        (row['asn'] as int, row['holder']?.toString() ?? ''),
  ];
}

Future<List<AsnOrigin>> lookupAsn(String address) async {
  if (!isPublicAsnAddress(address)) return const [];
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final uri = Uri.https('stat.ripe.net', '/data/prefix-overview/data.json',
        {'resource': address});
    final request =
        await client.getUrl(uri).timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200)
      throw HttpException('HTTP ${response.statusCode}');
    final result = BytesBuilder(copy: false);
    await response.forEach((chunk) {
      result.add(chunk);
      if (result.length > 65536) throw const FormatException('ASN 响应过大');
    }).timeout(const Duration(seconds: 5));
    return parseAsnOrigins(jsonDecode(utf8.decode(result.takeBytes())));
  } finally {
    client.close(force: true);
  }
}
