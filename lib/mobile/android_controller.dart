import 'dart:async';
import 'dart:convert';
import 'android_bridge.dart';

import 'package:flutter/foundation.dart';

import '../bridge/core_bridge.dart';
import '../services/store.dart';
import '../services/client_preferences.dart';
import '../services/node_selection.dart';
import '../services/active_profile.dart';
import '../services/clash_api.dart';
import '../services/local_ports.dart';
import '../services/node_tags.dart';
import '../services/subscription_fetcher.dart';
import '../services/subscription_nodes.dart';
import '../services/subscription_resolver.dart';
import '../services/import_content.dart';
import '../ui/diagnostics.dart';
import '../ui/import_dialog.dart';
import '../ui/preferences.dart';
import '../ui/runtime.dart';

class AndroidController extends ChangeNotifier {
  AndroidController({
    required this.bridge,
    required this.store,
    required this.data,
    this.fetcher,
  });
  final CoreBridge bridge;
  final Store store;
  final SubscriptionFetcher? fetcher;
  AppData data;
  final monitor = RuntimeMonitor();
  final delays = <int, int?>{};
  List<String> logs = [];
  List<Map<String, dynamic>> rules = [];
  bool busy = false,
      running = false,
      importing = false,
      cancelling = false,
      _committing = false,
      _disposed = false,
      _refreshing = false;
  String? message;
  String mode = 'rule';
  Timer? _timer, _sourceTimer;
  bool foreground = true;
  final _attempts = <String, DateTime>{};
  ClashApiClient get api =>
      ClashApiClient(port: data.clashApiPort, secret: data.clashApiSecret);
  void emit() {
    if (!_disposed) notifyListeners();
  }

  void report(Object value) {
    message = redactDiagnostics('$value');
    emit();
  }

  Future<void> initialize({bool poll = true}) async {
    final next = data.copyWith();
    final migrated = migrateSubscriptionNodes(next);
    if (next.clashApiSecret.isEmpty)
      next.clashApiSecret = generateClashSecret();
    if (migrated || data.clashApiSecret.isEmpty) await commit(next);
    await refresh();
    if (poll)
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (foreground) refresh();
      });
    if (!running && data.autoConnect && data.selected != null) await toggle();
    if (poll && !_disposed) {
      _sourceTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => refreshDueSources(),
      );
    }
  }

  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    final before = (running, mode, message);
    final previousLogs = logs;
    try {
      final status = await bridge.coreStatus();
      if (_disposed) return;
      running = status.running;
      if (status.lastExit != null)
        message = redactDiagnostics(status.lastExit!);
      logs = (await bridge.coreLogs()).map(redactDiagnostics).toList();
      monitor.configure(
        running: running,
        port: data.clashApiPort,
        secret: data.clashApiSecret,
      );
      if (running) {
        final client = api;
        try {
          mode = (await client.mode())?.toLowerCase() ?? 'rule';
          rules = await client.rules();
        } finally {
          client.close();
        }
      }
    } catch (e) {
      if (!busy) message = redactDiagnostics('$e');
    } finally {
      _refreshing = false;
      if (before != (running, mode, message) || !listEquals(previousLogs, logs))
        emit();
    }
  }

  void setForeground(bool value) {
    foreground = value;
    monitor.setSamplingEnabled(value);
  }

  Future<void> connectIfStopped() async {
    if (busy || running || await bridge.coreRunning() || busy || running)
      return;
    await toggle();
  }

  Future<void> commit(AppData next) async {
    final previous = data;
    try {
      await store.save(next);
      if (_disposed) return;
      data = next;
      emit();
    } catch (_) {
      try {
        await store.save(previous);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> operation(
    Future<void> Function() action, {
    bool propagate = false,
  }) async {
    if (busy || _disposed) {
      if (propagate) throw StateError('请等当前操作完成再保存');
      return;
    }
    busy = true;
    cancelling = false;
    emit();
    try {
      await action();
    } on ImportCancelled {
      report('已取消导入，原配置保留');
    } catch (e) {
      report('操作失败：${redactDiagnostics('$e')}');
      if (propagate) rethrow;
    } finally {
      busy = false;
      importing = false;
      _committing = false;
      emit();
    }
  }

  void cancelImport() {
    if (importing && !_committing) {
      cancelling = true;
      report('正在取消导入…');
    }
  }

  Future<void> toggle() => operation(() async {
        if (running) {
          await bridge.stopCore();
          running = false;
          monitor.configure(
            running: false,
            port: data.clashApiPort,
            secret: data.clashApiSecret,
          );
          report('VPN 已断开');
          return;
        }
        final selected = data.selected;
        if (selected == null) throw const FormatException('请先导入并选择节点');
        final profile = activeProfile(data), nodes = profileNodes(data);
        if (!nodes.contains(selected))
          throw const FormatException('请选择当前配置所属的出口节点');
        final next = data.copyWith();
        next.mixedPort = await findAvailablePort(data.mixedPort, {});
        next.clashApiPort = await findAvailablePort(data.clashApiPort, {
          next.mixedPort,
        });
        await commit(next);
        report('正在请求系统 VPN 授权并连接…');
        final config = await bridge.buildConfig(
          nodes: nodes
              .map((n) => NodeSpec(name: n.name, outboundJson: n.outboundJson))
              .toList(),
          mixedPort: data.mixedPort,
          clashApiPort: data.clashApiPort,
          enableTun: true,
          blockAds: data.blockAds,
          bypassCn: data.bypassCn,
          dataDir: store.dir.path,
          selectedName: assignNodeTags(
            nodes.map((n) => n.name),
          )[nodes.indexOf(selected)],
          profileJson: profile?.profileJson ?? '',
        );
        var runtimeConfig = applyClientPreferences(
          injectClashSecret(config, data.clashApiSecret),
          data.client,
          hasProfile: profile != null,
        );
        final android = bridge;
        if (android is AndroidCoreBridge && data.androidMtu != 1500) {
          final json = jsonDecode(runtimeConfig) as Map<String, dynamic>;
          final tun =
              (json['inbounds'] as List).firstWhere((i) => i['type'] == 'tun');
          tun['mtu'] = data.androidMtu;
          runtimeConfig = jsonEncode(json);
        }
        final file = await store.writeRuntimeConfig(runtimeConfig);
        if (android is AndroidCoreBridge) {
          await android.startCore(
              singBoxPath: 'libbox://1.14.4',
              configPath: file.path,
              excludedApps: data.androidExcludedApps,
              includedApps: data.androidIncludedApps);
        } else {
          await bridge.startCore(
              singBoxPath: 'libbox://1.14.4', configPath: file.path);
        }
        running = await bridge.coreRunning();
        if (!running) throw const FormatException('VPN 服务未就绪');
        monitor.configure(
          running: true,
          port: data.clashApiPort,
          secret: data.clashApiSecret,
        );
        report('VPN 已连接');
      });
  Future<void> select(int index) => operation(() async {
        final node = data.nodes[index];
        final nodes = profileNodes(data);
        if (!nodes.contains(node))
          throw const FormatException('此节点不属于当前完整配置，请先停止并切换配置');
        final next = data.copyWith();
        next.selectedIndex = index;
        if (running) {
          final client = api;
          try {
            final tag =
                assignNodeTags(nodes.map((n) => n.name))[nodes.indexOf(node)];
            final group = await client.proxy('proxy');
            if (group['all'] is List && !(group['all'] as List).contains(tag)) {
              throw const FormatException('该节点已保存，请断开并重新连接后使用');
            }
            await client.select('proxy', tag);
          } finally {
            client.close();
          }
        }
        try {
          await commit(next);
        } catch (_) {
          if (running && data.selected != null) {
            final client = api;
            try {
              await client.select(
                'proxy',
                assignNodeTags(nodes.map((n) => n.name))[nodes.indexOf(
                  data.selected!,
                )],
              );
            } finally {
              client.close();
            }
          }
          rethrow;
        }
        report('已选择 ${node.name}');
      });
  Future<void> activate(String id) => operation(() async {
        if (running) throw const FormatException('请先停止 VPN 再切换配置');
        final next = data.copyWith();
        next.activeProfileId = id;
        final nodes = profileNodes(next);
        next.selectedIndex = nodes.isEmpty
            ? -1
            : next.nodes.indexOf(
                nodes.firstWhere((n) => !n.isPolicy, orElse: () => nodes.first),
              );
        await commit(next);
        report('配置已切换');
      });
  Future<void> setMode(String value) => operation(() async {
        if (!running) throw const FormatException('连接后可切换路由模式');
        final client = api;
        try {
          await client.setMode(value);
          mode = value;
          emit();
        } finally {
          client.close();
        }
      });
  Future<void> measure(int index) => operation(() async {
        if (!running) throw const FormatException('先连接 VPN，才能通过内核进行真实代理测速');
        final nodes = profileNodes(data), node = data.nodes[index];
        if (!nodes.contains(node)) throw const FormatException('节点不属于当前配置');
        final client = api;
        try {
          delays[index] = await client.delay(
            assignNodeTags(nodes.map((n) => n.name))[nodes.indexOf(node)],
            url: data.client.testUrl,
            timeoutMs: data.client.testTimeoutMs,
          );
        } finally {
          client.close();
        }
        emit();
      });
  Future<void> removeNode(int index) => operation(() async {
        if (running) throw const FormatException('请停止 VPN 后删除');
        final old = data.selected, next = data.copyWith();
        next.nodes = [...next.nodes]..removeAt(index);
        next.selectedIndex = old == null ? -1 : next.nodes.indexOf(old);
        await commit(next);
      });
  Future<void> removeSource(Subscription source) => operation(() async {
        if (running) throw const FormatException('请停止 VPN 后删除');
        final next = data.copyWith();
        next.subscriptions =
            next.subscriptions.where((s) => s.id != source.id).toList();
        next.nodes = next.nodes.where((n) => n.source != source.id).toList();
        next.selectedIndex =
            data.selected == null ? -1 : next.nodes.indexOf(data.selected!);
        if (next.activeProfileId == source.id) next.activeProfileId = '';
        await commit(next);
      });
  Future<void> editSource(Subscription original, Subscription edited) =>
      operation(() async {
        if (running) throw const FormatException('请停止 VPN 后编辑');
        if (!data.subscriptions.contains(original))
          throw StateError('来源已更新，请重新打开编辑');
        final copy = data.copyWith();
        copy.subscriptions = [
          for (final s in copy.subscriptions) s.id == edited.id ? edited : s,
        ];
        await commit(copy);
        _attempts[edited.id] = DateTime.now();
      }, propagate: true);

  Future<void> saveClient(ClientPreferences value) => operation(() async {
        value.validate();
        final next = data.copyWith()..client = value;
        await commit(next);
      }, propagate: true);

  Future<void> restoreData(AppData restored) => operation(() async {
        if (running) throw StateError('请先停止 VPN 再恢复');
        await commit(restored..autoConnect = false);
        _attempts.clear();
        delays.clear();
        report('备份已恢复，VPN 保持断开');
      }, propagate: true);

  Future<void> refreshDueSources() async {
    if (!foreground || _disposed || running || busy) return;
    final now = DateTime.now();
    for (final source in data.subscriptions) {
      if (!source.isRemote || source.refreshMinutes <= 0) continue;
      final last = _attempts[source.id] ??
          DateTime.tryParse(source.lastAttemptAt ?? source.updatedAt ?? '');
      if (last != null &&
          now.difference(last).inMinutes < source.refreshMinutes) continue;
      await updateSource(source);
      return;
    }
  }

  Future<ParseOutcome> _resolve({
    required String url,
    String? content,
  }) async {
    final resolver = SubscriptionResolver(
      bridge: bridge,
      fetcher: fetcher ??
          HttpSubscriptionFetcher(
            verifyTls: data.desktop.verifyTls,
            userAgent: data.desktop.userAgent,
          ),
      isCancelled: () => cancelling || _disposed,
    );
    // Nodes-only by design (2026-11-21): subscriptions never import
    // their own routing / DNS, so the consent flow is gone entirely.
    return content == null
        ? await resolver.resolve(url, nodesOnly: true)
        : await resolver.resolveContent(content, nodesOnly: true);
  }

  Future<void> importRequest(ImportRequest request,
          {Future<bool> Function(String)? approve}) =>
      operation(() async {
        importing = true;
        report('正在解析导入来源…');
        final text = normalizeImportText(request.text),
            lines = text
                .split('\n')
                .map(normalizeImportText)
                .where((s) => s.isNotEmpty)
                .toList();
        final links = lines.isNotEmpty &&
            lines.every(
                (s) => RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s));
        final sources = <({String url, String? content, bool manual})>[];
        if (links) {
          final manual = <String>[];
          for (final line in lines) {
            if (isSubscriptionUrl(line)) {
              sources.add((url: line, content: null, manual: false));
            } else {
              manual.add(line);
            }
          }
          if (manual.isNotEmpty)
            sources.add((url: '', content: manual.join('\n'), manual: true));
        } else {
          sources.add((url: '', content: text, manual: request.manual));
        }
        final next = data.copyWith();
        final preview = <String>[];
        for (final source in sources) {
          final outcome = await _resolve(
            url: source.url,
            content: source.content,
          );
          if (cancelling || _disposed) throw const ImportCancelled();
          if (!outcome.nodes.any((n) => !n.isPolicy))
            throw const FormatException('没有识别到可用节点');
          final manual = source.manual;
          final id = manual
              ? ''
              : 'android-${DateTime.now().microsecondsSinceEpoch}-${next.subscriptions.length}';
          final nodes = outcome.nodes
              .where(isIndependentSubscriptionNode)
              .map((n) => n.withSource(id))
              .toList();
          final label = request.name.isNotEmpty
              ? request.name
              : source.url.isNotEmpty
                  ? Uri.parse(source.url).host
                  : '本地导入';
          final names = next.nodes.map((n) => n.name).toSet();
          final overlaps = nodes.where((n) => names.contains(n.name)).length;
          preview.add('$label：新增 ${nodes.length}，跳过 ${outcome.skipped.length}'
              '${overlaps == 0 ? '' : '，有 $overlaps 个同名节点，按来源保留'}');
          preview.addAll(outcome.skipped.take(4).map(redactDiagnostics));
          next.nodes = [...next.nodes, ...nodes];
          if (!manual)
            next.subscriptions = [
              ...next.subscriptions,
              Subscription(
                id: id,
                name: label,
                url: source.url,
                inlineContent: source.content,
                profileJson: outcome.profileJson,
                nodesOnly: outcome.nodesOnly,
                profileState:
                    outcome.profileJson == null ? 'nodes-only' : 'parsed',
                updatedAt: DateTime.now().toIso8601String(),
                lastReport: redactDiagnostics(outcome.skipped.join('\n')),
              ),
            ];
        }
        if (next.selectedIndex < 0 && next.nodes.isNotEmpty)
          next.selectedIndex = 0;
        if (approve != null && !await approve(preview.join('\n'))) {
          throw const ImportCancelled();
        }
        if (cancelling || _disposed) throw const ImportCancelled();
        _committing = true;
        await commit(next);
        report('导入已保存，共 ${data.nodes.where((n) => !n.isPolicy).length} 个节点'
            '${running ? '。重新连接后可使用新节点' : ''}');
      });
  Future<void> updateSource(Subscription source) => operation(() async {
        if (running) throw const FormatException('请先停止 VPN 再更新');
        if (!data.subscriptions.contains(source)) return;
        final attempt = DateTime.now();
        _attempts[source.id] = attempt;
        importing = true;
        report('正在更新 ${source.name}…');
        try {
          final outcome = await _resolve(
            url: source.url,
            content: source.inlineContent,
          );
          if (cancelling || _disposed) throw const ImportCancelled();
          if (!outcome.nodes.any((n) => !n.isPolicy))
            throw const FormatException('新来源不含可用节点，已保留旧数据');
          final fresh =
              outcome.nodes.map((n) => n.withSource(source.id)).toList();
          final previous =
              data.nodes.where((n) => n.source == source.id).toList();
          final retained = retainFailedSourceNodes(
            previous,
            fresh,
            outcome.failedGroups,
          );
          final next = data.copyWith();
          final replacement = resolvePolicyGroups([...fresh, ...retained]);
          next.nodes = [
            ...next.nodes.where((n) => n.source != source.id),
            ...replacement,
          ];
          next.subscriptions = next.subscriptions
              .map(
                (s) => s.id == source.id
                    ? Subscription(
                        id: s.id,
                        name: s.name,
                        url: s.url,
                        inlineContent: s.inlineContent,
                        localPath: s.localPath,
                        refreshMinutes: s.refreshMinutes,
                        lastAttemptAt: attempt.toIso8601String(),
                        nodesOnly: outcome.nodesOnly,
                        profileJson: outcome.profileJson,
                        profileState: outcome.profileJson == null
                            ? 'nodes-only'
                            : 'parsed',
                        lastReport:
                            redactDiagnostics(outcome.skipped.join('\n')),
                        updatedAt: DateTime.now().toIso8601String(),
                      )
                    : s,
              )
              .toList();
          if (next.activeProfileId == source.id && outcome.profileJson == null)
            next.activeProfileId = '';
          final selected = data.selected;
          next.selectedIndex =
              selected == null ? -1 : next.nodes.indexOf(selected);
          if (selected != null && selected.source == source.id) {
            final index = restoredNodeIndex(selected, previous, replacement);
            next.selectedIndex =
                index < 0 ? -1 : next.nodes.indexOf(replacement[index]);
          }
          if (next.selected != null &&
              !profileNodes(next).contains(next.selected))
            next.selectedIndex = -1;
          _committing = true;
          await commit(next);
          delays.clear();
          report(
            selected != null && next.selectedIndex < 0
                ? '来源已更新，原出口无法唯一匹配，请重新选择'
                : '来源更新已保存',
          );
        } on ImportCancelled {
          rethrow;
        } catch (error) {
          final next = data.copyWith();
          next.subscriptions = [
            for (final s in data.subscriptions)
              if (s.id == source.id)
                s.copyWith(
                  lastAttemptAt: attempt.toIso8601String(),
                  lastError: redactDiagnostics('$error'),
                )
              else
                s,
          ];
          await commit(next);
          rethrow;
        }
      });
  Future<void> appearance(UiPreferences value) => operation(() async {
        final next = data.copyWith();
        next.ui = value;
        await commit(next);
      });
  Future<void> saveVpnSettings(
          {int? mtu,
          List<String>? excludedApps,
          List<String>? includedApps,
          bool allApps = false}) =>
      operation(() async {
        final next = data.copyWith();
        if (mtu != null) {
          if (![1280, 1400, 1500].contains(mtu))
            throw const FormatException('不支持的 MTU');
          next.androidMtu = mtu;
        }
        if (excludedApps != null) {
          if (excludedApps.length > 512) throw const FormatException('排除应用过多');
          next.androidExcludedApps = excludedApps.toSet().toList();
          next.androidIncludedApps = null;
        }
        if (includedApps != null) {
          if (includedApps.isEmpty || includedApps.length > 512) {
            throw const FormatException('请选择 1 至 512 个允许通过 VPN 的应用');
          }
          next.androidIncludedApps = includedApps.toSet().toList();
        }
        if (allApps) {
          next.androidIncludedApps = null;
          next.androidExcludedApps = [];
        }
        await commit(next);
        report(running ? 'VPN 设置已保存，下次连接生效' : 'VPN 设置已保存');
      }, propagate: true);

  Future<void> saveOptions({
    bool? autoConnect,
    bool? verifyTls,
    String? userAgent,
  }) =>
      operation(() async {
        if (userAgent != null &&
            (userAgent.contains(RegExp(r'[\r\n]')) ||
                userAgent.length > 512 ||
                userAgent.codeUnits.any((c) => c > 255)))
          throw const FormatException('User-Agent 需为单行 HTTP 字符，最长512字符');
        final next = data.copyWith();
        if (autoConnect != null) next.autoConnect = autoConnect;
        next.desktop = next.desktop.copyWith(
          verifyTls: verifyTls,
          userAgent: userAgent,
        );
        await commit(next);
        report('设置已保存');
      });
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _sourceTimer?.cancel();
    monitor.dispose();
    super.dispose();
  }
}
