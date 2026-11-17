/// Values are local preferences; old data files load unchanged.
class DesktopSettings {
  const DesktopSettings(
      {this.launchAtLogin = false,
      this.silentStart = false,
      this.autoRun = false,
      this.onDemand = false,
      this.processes = const [],
      this.userAgent = '',
      this.verifyTls = true,
      this.autoCheckUpdates = true,
      this.allowLan = false,
      this.remoteController = false,
      this.proxyAuth = false,
      this.proxyUser = '',
      this.proxyPassword = ''});
  final bool launchAtLogin,
      silentStart,
      autoRun,
      onDemand,
      verifyTls,
      autoCheckUpdates,
      allowLan,
      remoteController,
      proxyAuth;
  final List<String> processes;
  final String userAgent, proxyUser, proxyPassword;
  factory DesktopSettings.fromJson(dynamic raw) {
    final m = raw is Map ? raw : const {};
    bool b(String k, bool fallback) => m[k] is bool ? m[k] as bool : fallback;
    String s(String k) => m[k] is String ? m[k] as String : '';
    return DesktopSettings(
        launchAtLogin: b('launchAtLogin', false),
        silentStart: b('silentStart', false),
        autoRun: b('autoRun', false),
        onDemand: b('onDemand', false),
        processes: m['processes'] is List
            ? (m['processes'] as List).whereType<String>().toList()
            : const [],
        userAgent: s('userAgent'),
        verifyTls: b('verifyTls', true),
        autoCheckUpdates: b('autoCheckUpdates', true),
        allowLan: b('allowLan', false),
        remoteController: b('remoteController', false),
        proxyAuth: b('proxyAuth', false),
        proxyUser: s('proxyUser'),
        proxyPassword: s('proxyPassword'));
  }
  Map<String, dynamic> toJson() => {
        'launchAtLogin': launchAtLogin,
        'silentStart': silentStart,
        'autoRun': autoRun,
        'onDemand': onDemand,
        'processes': processes,
        'userAgent': userAgent,
        'verifyTls': verifyTls,
        'autoCheckUpdates': autoCheckUpdates,
        'allowLan': allowLan,
        'remoteController': remoteController,
        'proxyAuth': proxyAuth,
        'proxyUser': proxyUser,
        'proxyPassword': proxyPassword
      };
  DesktopSettings copyWith(
          {bool? launchAtLogin,
          bool? silentStart,
          bool? autoRun,
          bool? onDemand,
          List<String>? processes,
          String? userAgent,
          bool? verifyTls,
          bool? autoCheckUpdates,
          bool? allowLan,
          bool? remoteController,
          bool? proxyAuth,
          String? proxyUser,
          String? proxyPassword}) =>
      DesktopSettings(
          launchAtLogin: launchAtLogin ?? this.launchAtLogin,
          silentStart: silentStart ?? this.silentStart,
          autoRun: autoRun ?? this.autoRun,
          onDemand: onDemand ?? this.onDemand,
          processes: processes ?? this.processes,
          userAgent: userAgent ?? this.userAgent,
          verifyTls: verifyTls ?? this.verifyTls,
          autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
          allowLan: allowLan ?? this.allowLan,
          remoteController: remoteController ?? this.remoteController,
          proxyAuth: proxyAuth ?? this.proxyAuth,
          proxyUser: proxyUser ?? this.proxyUser,
          proxyPassword: proxyPassword ?? this.proxyPassword);
}
