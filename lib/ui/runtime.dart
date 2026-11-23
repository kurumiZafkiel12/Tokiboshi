import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../services/clash_api.dart';

/// Samples actual controller totals. No simulated traffic or success states.
class RuntimeMonitor extends ChangeNotifier {
  ClashApiClient? _api;
  Timer? _timer;
  bool _fetching = false, _disposed = false;
  int _generation = 0;
  bool _samplingEnabled = true;
  int download = 0, upload = 0;
  double downSpeed = 0, upSpeed = 0;
  DateTime? startedAt, _lastSample;
  List<Map<String, dynamic>> connections = [];
  List<double> downHistory = [], upHistory = [];
  String? error;
  bool available = false;
  int? _port;
  String? _secret;
  void configure(
      {required bool running, required int port, required String secret}) {
    if (!running) {
      if (_api == null) return;
      _generation++;
      _api?.close();
      _api = null;
      _timer?.cancel();
      _port = null;
      available = false;
      connections = [];
      downSpeed = 0;
      upSpeed = 0;
      startedAt = null;
      _lastSample = null;
      error = null;
      notifyListeners();
      return;
    }
    if (_api != null && port == _port && secret == _secret) return;
    _generation++;
    _api?.close();
    _timer?.cancel();
    _api = ClashApiClient(port: port, secret: secret);
    _port = port;
    _secret = secret;
    startedAt = DateTime.now();
    _lastSample = null;
    download = 0;
    upload = 0;
    downHistory = [];
    upHistory = [];
    _startSampling();
  }

  void setSamplingEnabled(bool enabled) {
    if (_samplingEnabled == enabled) return;
    _samplingEnabled = enabled;
    _timer?.cancel();
    _lastSample = null;
    _startSampling();
  }

  void _startSampling() {
    if (!_samplingEnabled || _api == null || _disposed) return;
    sample();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => sample());
  }

  Future<void> sample() async {
    final api = _api;
    final generation = _generation;
    if (api == null || _fetching || _disposed || !_samplingEnabled) return;
    _fetching = true;
    try {
      final v = await api.connections();
      if (_disposed || generation != _generation || !_samplingEnabled) return;
      final now = DateTime.now();
      final nextDown = (v['downloadTotal'] as num?)?.toInt() ?? 0;
      final nextUp = (v['uploadTotal'] as num?)?.toInt() ?? 0;
      final elapsed = _lastSample == null
          ? 0.0
          : now.difference(_lastSample!).inMicroseconds / 1000000;
      downSpeed = elapsed > 0 ? math.max(0, nextDown - download) / elapsed : 0;
      upSpeed = elapsed > 0 ? math.max(0, nextUp - upload) / elapsed : 0;
      download = nextDown;
      upload = nextUp;
      _lastSample = now;
      connections = (v['connections'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      downHistory = [...downHistory, downSpeed];
      upHistory = [...upHistory, upSpeed];
      if (downHistory.length > 60) downHistory.removeAt(0);
      if (upHistory.length > 60) upHistory.removeAt(0);
      available = true;
      error = null;
      notifyListeners();
    } catch (_) {
      if (!_disposed && generation == _generation && _samplingEnabled) {
        available = false;
        error = '控制器暂不可达，正在重试';
        downSpeed = 0;
        upSpeed = 0;
        notifyListeners();
      }
    } finally {
      _fetching = false;
    }
  }

  Future<void> closeConnections([String? id]) async {
    final api = _api;
    if (api == null) throw StateError('控制器未连接，无法关闭请求');
    await api.closeConnections(id);
    await sample();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _api?.close();
    super.dispose();
  }
}
