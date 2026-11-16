import 'dart:convert';
import 'dart:io';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:tokiboshi/src/rust/frb_generated.dart';
import 'package:tokiboshi/bridge/rust_core_bridge.dart';
import 'package:tokiboshi/bridge/core_bridge.dart';
import 'package:tokiboshi/services/subscription_resolver.dart';
import 'package:tokiboshi/services/subscription_fetcher.dart';

Future<void> main() async {
 final env=Platform.environment;
 final out=Directory(env['T069_OUT']!);await out.create(recursive:true);
 await RustLib.init(externalLibrary:ExternalLibrary.open(env['T069_DLL']!));
 final bridge=RustCoreBridge();
 final results=<String,dynamic>{};
 try {
  final yaml='''proxies:
  - {name: A, type: socks5, server: 127.0.0.1, port: ${env['T069_NODE_A']}}
  - {name: B, type: socks5, server: 127.0.0.1, port: ${env['T069_NODE_B']}}
proxy-groups:
  - {name: Group, type: select, proxies: [B]}
rules:
  - DOMAIN,blocked.example,REJECT
  - IP-CIDR,127.0.0.1/32,REJECT,no-resolve
  - DOMAIN,localhost,Group
  - MATCH,A
dns:
  nameserver: [1.1.1.1]
''';
  final parsed=await bridge.parseSubscription(yaml);
  if(parsed.profileJson==null) throw StateError('profile lost through FRB');
  final nodes=parsed.nodes.map((n)=>NodeSpec(name:n.name,outboundJson:n.outboundJson)).toList();
  Future<String> build(String? p)=>bridge.buildConfig(nodes:nodes,
   mixedPort:int.parse(env['T069_MIXED']!),clashApiPort:int.parse(env['T069_API']!),
   dataDir:out.path,selectedName:'A',profileJson:p??'');
  final config=await build(parsed.profileJson);final v=jsonDecode(config);
  await File('${out.path}/bridge-runtime.json').writeAsString(config);
  final check=await Process.run(env['SING_BOX']!,['check','-c','${out.path}/bridge-runtime.json']);
  results['bridgeParseAndBuild']={'profilePresent':true,'final':v['route']['final'],
    'ruleTargets':v['route']['rules'],'dns':v['dns'],'checkExit':check.exitCode};
  if(check.exitCode!=0) throw StateError('core check failed: ${check.stderr}');
  final changed=await bridge.parseSubscription(yaml.replaceAll('1.1.1.1','8.8.8.8').replaceAll('DOMAIN,localhost,Group','DOMAIN,changed.example,A'));
  final changedConfig=await build(changed.profileJson);
  results['sameNodesDifferentRulesAndDns']=jsonEncode(jsonDecode(config))!=jsonEncode(jsonDecode(changedConfig));
  if(results['sameNodesDifferentRulesAndDns']!=true)throw StateError('profile ignored');
  final invalid=<String>[];
  for(final text in ['not-json',jsonEncode({...jsonDecode(parsed.profileJson!),'unsupported':['dns.fixture unsupported']})]) {
   try {await build(text);throw StateError('invalid profile accepted');}
   catch(e){if(e.toString().contains('invalid profile accepted'))rethrow;invalid.add(e.runtimeType.toString());}
  }
  results['invalidAndUnsupportedRejected']=invalid;
  final pure=await bridge.parseSubscription('socks://127.0.0.1:1#plain');
  results['nodesOnlyProfileNull']=pure.profileJson==null;
  if(pure.profileJson!=null)throw StateError('invented profile');
  final converted=jsonDecode(await bridge.convertRuleProvider(text: "payload:\n - '+.example.com'\n",behavior:'domain',format:'yaml'));
  if(converted[0]['domain_suffix'][0]!='example.com')throw StateError('provider conversion failed');
  results['yamlProviderConverted']=converted;
  final providerYaml=yaml.replaceFirst('DOMAIN,localhost,Group','RULE-SET,sites,Group')+
      '\nrule-providers:\n  sites: {type: http, behavior: domain, format: yaml, url: /rules.yaml}\n';
  final resolved=await SubscriptionResolver(bridge:bridge,fetcher:FakeFetcher({
    'https://fixture.example/root':providerYaml,'https://fixture.example/rules.yaml':'payload:\n - localhost\n'
  })).resolve('https://fixture.example/root');
  final providerConfig=await build(resolved.profileJson);
  final sets=jsonDecode(providerConfig)['route']['rule_set'] as List;
  if(sets.single['type']!='inline')throw StateError('raw provider escaped conversion');
  await File('${out.path}/bridge-runtime.json').writeAsString(providerConfig);
  final providerCheck=await Process.run(env['SING_BOX']!,['check','-c','${out.path}/bridge-runtime.json']);
  if(providerCheck.exitCode!=0)throw StateError('converted provider failed check: ${providerCheck.stderr}');
  results['rootProviderPipeline']={'inline':true,'checkExit':providerCheck.exitCode};
  results['passed']=true;
 } finally {
  await File('${out.path}/bridge-probe-results.json').writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  RustLib.dispose();
 }
}
