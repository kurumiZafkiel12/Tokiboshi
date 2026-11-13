/// Bridge between the Flutter UI and the Rust middle layer.
///
/// The Rust layer (`rust/src/api/core.rs`) is the real implementation.
/// Its functions are bound with flutter_rust_bridge; the generated
/// bindings live in `lib/src/rust/` after running
/// `flutter_rust_bridge_codegen generate`.
///
/// [LocalCoreBridge] mirrors the Rust `config.rs` logic in Dart so the
/// UI is runnable and testable before code generation, and widget tests
/// can substitute a fake. Behaviour must stay in sync with the Rust
/// unit tests, which are the authority.
library;

import 'dart:convert';

enum CoreState { stopped, running }

abstract class CoreBridge {
  CoreState get state;

  /// Validate a full sing-box config. Empty list means valid.
  List<String> validateConfig(String text);

  /// Build a full sing-box config around one outbound JSON object.
  /// Throws [FormatException] with the Rust layer's error message.
  String buildConfig({
    required String outboundJson,
    int mixedPort = 7890,
    bool enableTun = false,
  });

  Future<void> start(String configJson);
  Future<void> stop();
}

/// Dart mirror of the Rust middle layer's config logic.
class LocalCoreBridge implements CoreBridge {
  CoreState _state = CoreState.stopped;
  String? runningConfig;

  @override
  CoreState get state => _state;

  @override
  List<String> validateConfig(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      return ['invalid JSON: ${e.message}'];
    }
    if (decoded is! Map<String, dynamic>) {
      return ['top level must be a JSON object'];
    }
    final problems = <String>[];
    final outbounds = decoded['outbounds'];
    if (outbounds == null) {
      problems.add('missing "outbounds"');
    } else if (outbounds is! List) {
      problems.add('"outbounds" must be an array');
    } else {
      if (outbounds.isEmpty) {
        problems.add('"outbounds" must not be empty');
      }
      for (var i = 0; i < outbounds.length; i++) {
        final ob = outbounds[i];
        final type = ob is Map ? ob['type'] : null;
        if (type == null) {
          problems.add('outbounds[$i] missing "type"');
        } else if (type == '') {
          problems.add('outbounds[$i] has empty "type"');
        }
      }
    }
    final inbounds = decoded['inbounds'];
    if (inbounds != null && inbounds is! List) {
      problems.add('"inbounds" must be an array');
    }
    return problems;
  }

  @override
  String buildConfig({
    required String outboundJson,
    int mixedPort = 7890,
    bool enableTun = false,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(outboundJson);
    } on FormatException catch (e) {
      throw FormatException('invalid outbound JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('outbound must be a JSON object');
    }
    final type = decoded['type'];
    if (type == null || type == '') {
      throw const FormatException('outbound missing "type"');
    }
    if (mixedPort == 0) {
      throw const FormatException('mixed_port must not be 0');
    }
    final node = Map<String, dynamic>.from(decoded);
    node.putIfAbsent('tag', () => 'proxy');
    final inbounds = <Map<String, dynamic>>[
      {
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      },
      if (enableTun)
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30'],
          'auto_route': true,
          'strict_route': true,
          'stack': 'mixed',
        },
    ];
    final config = <String, dynamic>{
      'log': {'level': 'info', 'timestamp': true},
      'inbounds': inbounds,
      'outbounds': [
        node,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'proxy', 'auto_detect_interface': true},
    };
    return const JsonEncoder.withIndent('  ').convert(config);
  }

  @override
  Future<void> start(String configJson) async {
    if (_state == CoreState.running) {
      throw StateError('sing-box is already running');
    }
    final problems = validateConfig(configJson);
    if (problems.isNotEmpty) {
      throw FormatException(problems.join('; '));
    }
    runningConfig = configJson;
    _state = CoreState.running;
  }

  @override
  Future<void> stop() async {
    _state = CoreState.stopped;
    runningConfig = null;
  }
}
