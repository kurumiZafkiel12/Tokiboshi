/// Keep in sync with Rust config::assign_tags. Clash API selects generated tags.
List<String> assignNodeTags(Iterable<String> names) {
  final used = {'proxy', 'auto', 'direct', 'mixed-in', 'tun-in', 'dns-remote', 'dns-local'};
  final tags = <String>[];
  for (final name in names) {
    final base = name.trim().isEmpty ? 'node-${tags.length + 1}' : name.trim();
    var tag = base;
    var suffix = 2;
    while (used.contains(tag)) { tag = '$base-$suffix'; suffix++; }
    used.add(tag);
    tags.add(tag);
  }
  return tags;
}
