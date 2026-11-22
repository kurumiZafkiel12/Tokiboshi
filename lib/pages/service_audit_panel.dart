import 'dart:io';
import 'package:flutter/material.dart';
import '../services/service_audit.dart';
import '../ui/design.dart';

class ServiceAuditPanel extends StatefulWidget {
  const ServiceAuditPanel({super.key, required this.createClient});
  final HttpClient Function() createClient;

  @override
  State<ServiceAuditPanel> createState() => _ServiceAuditPanelState();
}

class _ServiceAuditPanelState extends State<ServiceAuditPanel> {
  final _results = <ServiceAuditResult>[];
  HttpClient? _client;

  Future<void> _start() async {
    final client = widget.createClient();
    setState(() {
      _client = client;
      _results.clear();
    });
    try {
      for (var i = 0; i < serviceNames.length; i += 2) {
        final rows = await Future.wait(serviceNames
            .skip(i)
            .take(2)
            .map((service) => auditService(client, service)));
        if (!mounted || _client != client) return;
        setState(() => _results.addAll(rows));
      }
    } finally {
      client.close(force: true);
      if (mounted && _client == client) setState(() => _client = null);
    }
  }

  void _cancel() {
    _client?.close(force: true);
    setState(() => _client = null);
  }

  @override
  void dispose() {
    _client?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Panel(
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('服务解锁与地区检测',
                    style: Theme.of(context).textTheme.titleLarge),
                FilledButton.icon(
                    onPressed: _client == null ? _start : _cancel,
                    icon: Icon(_client == null
                        ? Icons.play_arrow_rounded
                        : Icons.stop_rounded),
                    label: Text(_client == null ? '开始测试' : '取消测试')),
              ]),
          const SizedBox(height: 8),
          const Text('走本机代理入站，实际出口取决于当前规则。仅测试公开端点和地区信号，登录、订阅、DRM 和播放需单独确认。'),
          const SizedBox(height: 12),
          if (_client != null)
            LinearProgressIndicator(
                value: _results.length / serviceNames.length),
          for (final (service, result, evidence) in _results)
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    result.contains('受限') ? Icons.public_off : Icons.public),
                title: Text(service),
                subtitle: Text(evidence),
                trailing: Text(result)),
        ],
      ));
}
