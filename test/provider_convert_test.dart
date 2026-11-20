import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/main.dart';

void main() {
  test('domain provider payload converts to source rule-set', () {
    final out = convertProviderPayloadToSource(
        '- DOMAIN,ads.a.com\n- DOMAIN-SUFFIX,ads.b.com\n- DOMAIN-KEYWORD,ads\n# comment\n', 'domain');
    expect(out['version'], 1);
    final rules = out['rules'] as List;
    expect((rules[0]['domain'] as List).first, 'ads.a.com');
    expect((rules[1]['domain_suffix'] as List).first, 'ads.b.com');
    expect((rules[2]['keyword'] as List).first, 'ads');
  });

  test('ipcidr provider payload collects cidr entries', () {
    final out = convertProviderPayloadToSource(
        '- IP-CIDR,10.0.0.0/8\n- IP-CIDR6,fe80::/10\n- DOMAIN,junk.com', 'ipcidr');
    final rules = out['rules'] as List;
    expect(rules, hasLength(1));
    expect((rules[0]['ip_cidr'] as List), hasLength(2));
  });

  test('classic provider payload keeps targets as outbound', () {
    final out = convertProviderPayloadToSource(
        '- DOMAIN-SUFFIX,openai.net,PROXY\n- IP-CIDR,1.1.1.1/32,DIRECT', 'classic');
    final rules = out['rules'] as List;
    expect(rules, hasLength(2));
    expect(rules[0]['outbound'], 'PROXY');
    expect(rules[1]['outbound'], 'DIRECT');
  });

  test('empty payload throws', () {
    expect(() => convertProviderPayloadToSource('# only comments', 'domain'),
        throwsFormatException);
  });
}
