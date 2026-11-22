import 'dart:convert';
import 'dart:io';
import '../bridge/core_bridge.dart';
import 'routing_targets.dart';

typedef QualityRound = ({DateTime at, List<int?> samples});

/// Last completed kernel URL test for each node and test configuration.
class QualityHistory {
  QualityHistory(Directory directory)
      : _file = File('${directory.path}/quality-history.json');
  final File _file;
  final _rounds = <String, QualityRound>{};
  bool _loaded = false;

  String key(NodeInfo node, String endpoint, int timeout) =>
      jsonEncode([routeNodeReference(node), endpoint, timeout]);

  QualityRound? lookup(String key) {
    if (!_loaded) {
      _loaded = true;
      try {
        final rows = jsonDecode(_file.readAsStringSync()) as Map;
        for (final e in rows.entries) {
          final values = (e.value['samples'] as List).cast<int?>().toList();
          if (values.length == 5) {
            _rounds[e.key as String] =
                (at: DateTime.parse(e.value['at']), samples: values);
          }
        }
      } catch (_) {
        // Missing or obsolete cache: measurements can always be taken again.
      }
    }
    return _rounds[key];
  }

  Future<void> _pending = Future.value();
  Future<void> save(String key, List<int?> samples) {
    lookup(key);
    _rounds.remove(key);
    _rounds[key] = (at: DateTime.now(), samples: List.of(samples));
    while (_rounds.length > 256) {
      _rounds.remove(_rounds.keys.first);
    }
    final write = _pending.then((_) async {
      final temp = File('${_file.path}.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(
          jsonEncode({
            for (final e in _rounds.entries)
              e.key: {
                'at': e.value.at.toIso8601String(),
                'samples': e.value.samples
              }
          }),
          flush: true);
      await temp.rename(_file.path);
    });
    _pending = write.catchError((Object _) {});
    return write;
  }
}
