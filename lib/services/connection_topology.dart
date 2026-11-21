typedef TopologyKey = (int, String);
typedef TopologyEdge = (TopologyKey, TopologyKey);

class TopologyStats {
  int count = 0, upload = 0, download = 0;
  final rules = <String>{};
  void add(Map<String, dynamic> row, String rule) {
    count++;
    upload += (row['upload'] as num?)?.toInt() ?? 0;
    download += (row['download'] as num?)?.toInt() ?? 0;
    rules.add(rule);
  }
}

class ConnectionTopology {
  final nodes = <TopologyKey, TopologyStats>{};
  final edges = <TopologyEdge, TopologyStats>{};

  ConnectionTopology(Iterable<Map<String, dynamic>> connections,
      {required bool byIp}) {
    final paths = connections.map((row) {
      final rawChain = row['chains'];
      final chain =
          rawChain is List ? rawChain.whereType<String>().toList() : <String>[];
      final rule = [row['rule'], row['rulePayload']]
          .whereType<String>()
          .where((x) => x.isNotEmpty)
          .join(',');
      final meta = row['metadata'] is Map ? row['metadata'] as Map : const {};
      final layers = [
        [chain.firstOrNull ?? '未标记'],
        chain.length > 1 ? chain.skip(1).toSet().toList() : ['未标记'],
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
          for (final prev in previous) {
            edges.putIfAbsent((prev, key), TopologyStats.new).add(row, rule);
          }
        }
        previous = keys;
      }
    }
  }
}
