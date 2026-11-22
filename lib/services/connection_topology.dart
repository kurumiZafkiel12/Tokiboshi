typedef TopologyKey = (int, String);
typedef TopologyEdge = (TopologyKey, TopologyKey);

class TopologyStats {
  int count = 0, upload = 0, download = 0;
  final rules = <String>{};
  final destinations = <String>{};
  final addresses = <String>{};
  void add(Map<String, dynamic> row, String rule) {
    count++;
    upload += (row['upload'] as num?)?.toInt() ?? 0;
    download += (row['download'] as num?)?.toInt() ?? 0;
    rules.add(rule);
    final meta = row['metadata'] is Map ? row['metadata'] as Map : const {};
    final host = '${meta['host'] ?? meta['destinationIP'] ?? ''}';
    final port = '${meta['destinationPort'] ?? ''}';
    for (final key in ['sourceIP', 'destinationIP']) {
      final address = meta[key];
      if (address is String && address.isNotEmpty && addresses.length < 24) {
        addresses.add(address);
      }
    }
    if (host.isNotEmpty) {
      destinations.add(port.isEmpty ? host : '$host:$port');
    }
    if (destinations.length > 50) destinations.remove(destinations.first);
  }
}

class ConnectionTopology {
  final nodes = <TopologyKey, TopologyStats>{};
  final edges = <TopologyEdge, TopologyStats>{};
  final rates = <TopologyKey, (double, double)>{};

  ConnectionTopology(Iterable<Map<String, dynamic>> connections,
      {required bool byIp, Map<String, (double, double)> deltas = const {}}) {
    final paths = connections.map((row) {
      final rawChain = row['chains'];
      // sing-box 1.14 emits the selected exit first, outer selector last.
      final chain = rawChain is List
          ? rawChain.whereType<String>().toList().reversed.toList()
          : <String>[];
      final rule = [row['rule'], row['rulePayload']]
          .whereType<String>()
          .where((x) => x.isNotEmpty)
          .join(',');
      final meta = row['metadata'] is Map ? row['metadata'] as Map : const {};
      final layers = [
        [chain.length > 1 ? chain.first : '无代理组'],
        chain.isEmpty
            ? ['未标记']
            : chain.skip(chain.length > 1 ? 1 : 0).toSet().toList(),
        [rule.isEmpty ? '未标记' : rule],
        ['${meta[byIp ? 'sourceIP' : 'sourcePort'] ?? '未知'}'],
      ];
      return (row, layers, layers[2].single);
    }).toList();
    final counters = List.generate(4, (_) => <String, int>{});
    for (final (_, layers, _) in paths) {
      for (var i = 0; i < 4; i++) {
        for (final label in layers[i]) {
          counters[i].update(label, (value) => value + 1, ifAbsent: () => 1);
        }
      }
    }
    final retained = counters.map((labels) {
      final ordered = labels.keys.toList()
        ..sort((a, b) {
          final weight = labels[b]!.compareTo(labels[a]!);
          return weight == 0 ? a.compareTo(b) : weight;
        });
      return ordered.take(ordered.length > 24 ? 23 : 24).toSet();
    }).toList();
    for (final (row, layers, rule) in paths) {
      var previous = <TopologyKey>{};
      for (var i = 0; i < 4; i++) {
        final keys = layers[i]
            .map((label) => (
                  i,
                  retained[i].contains(label)
                      ? label
                      : '…+${counters[i].length - retained[i].length}'
                ))
            .toSet();
        for (final key in keys) {
          nodes.putIfAbsent(key, TopologyStats.new).add(row, rule);
          final rate = deltas[row['id']];
          if (rate != null) {
            final old = rates[key] ?? (0.0, 0.0);
            rates[key] = (old.$1 + rate.$1, old.$2 + rate.$2);
          }
          for (final prev in previous) {
            edges.putIfAbsent((prev, key), TopologyStats.new).add(row, rule);
          }
        }
        previous = keys;
      }
    }
  }
}

class ConnectionRateSampler {
  List<Map<String, dynamic>>? _last;
  Map<String, (num, num)> _counters = {};
  Map<String, (double, double)> _rates = {};
  Duration? _sampleTime;

  Map<String, (double, double)> update(
      List<Map<String, dynamic>> rows, Duration now) {
    if (identical(rows, _last)) return _rates;
    final old = _sampleTime;
    final seconds = old == null ? 0 : (now - old).inMicroseconds / 1000000;
    final next = <String, (num, num)>{};
    final rates = <String, (double, double)>{};
    for (final row in rows) {
      final id = row['id'], up = row['upload'], down = row['download'];
      if (id is! String || up is! num || down is! num) continue;
      next[id] = (up, down);
      final previous = _counters[id];
      if (seconds > 0 &&
          seconds <= 4 &&
          previous != null &&
          up >= previous.$1 &&
          down >= previous.$2) {
        rates[id] =
            ((up - previous.$1) / seconds, (down - previous.$2) / seconds);
      }
    }
    _last = rows;
    _sampleTime = now;
    _counters = next;
    return _rates = rates;
  }

  void reset() {
    _last = null;
    _sampleTime = null;
    _counters = {};
    _rates = {};
  }
}
