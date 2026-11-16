import 'package:flutter/material.dart';

/// Appearance only. Invalid/old preferences cannot invalidate saved nodes.
class UiPreferences {
  const UiPreferences(
      {this.light = false,
      this.motion = 'full',
      this.previousMotion = 'full',
      this.followSystem = true,
      this.character = true,
      this.flow = true,
      this.compact = false,
      this.closeToTray = true,
      this.order = const ['status', 'traffic', 'profile', 'runtime']});
  final bool light, followSystem, character, flow, compact, closeToTray;
  final String motion, previousMotion;
  final List<String> order;
  factory UiPreferences.fromJson(dynamic value) {
    final m = value is Map ? value : const {};
    bool flag(String k, bool fallback) =>
        m[k] is bool ? m[k] as bool : fallback;
    final order = <String>['status'];
    if (m['order'] is List) {
      for (final key in m['order']) {
        if (const ['traffic', 'profile', 'runtime'].contains(key) &&
            !order.contains(key)) order.add(key as String);
      }
    }
    for (final key in const ['traffic', 'profile', 'runtime']) {
      if (!order.contains(key)) order.add(key);
    }
    return UiPreferences(
        light: flag('light', false),
        motion: const ['full', 'standard', 'reduced'].contains(m['motion'])
            ? m['motion'] as String
            : 'full',
        previousMotion: const ['full', 'standard'].contains(m['previousMotion'])
            ? m['previousMotion'] as String
            : m['motion'] == 'standard'
                ? 'standard'
                : 'full',
        followSystem: flag('followSystem', true),
        character: flag('character', true),
        flow: flag('flow', true),
        compact: flag('compact', false),
        closeToTray: flag('closeToTray', true),
        order: order);
  }
  Map<String, dynamic> toJson() => {
        'light': light,
        'motion': motion,
        'previousMotion': previousMotion,
        'followSystem': followSystem,
        'character': character,
        'flow': flow,
        'compact': compact,
        'closeToTray': closeToTray,
        'order': order
      };
  UiPreferences copyWith(
          {bool? light,
          String? motion,
          String? previousMotion,
          bool? followSystem,
          bool? character,
          bool? flow,
          bool? compact,
          bool? closeToTray,
          List<String>? order}) =>
      UiPreferences(
          light: light ?? this.light,
          motion: motion ?? this.motion,
          previousMotion: previousMotion ??
              (motion != null && motion != "reduced"
                  ? motion
                  : this.previousMotion),
          followSystem: followSystem ?? this.followSystem,
          character: character ?? this.character,
          flow: flow ?? this.flow,
          compact: compact ?? this.compact,
          closeToTray: closeToTray ?? this.closeToTray,
          order: order ?? this.order);
}

class UiScope extends InheritedNotifier<ValueNotifier<UiPreferences>> {
  const UiScope(
      {super.key,
      required ValueNotifier<UiPreferences> controller,
      required this.onChanged,
      required super.child})
      : super(notifier: controller);
  final ValueChanged<UiPreferences> onChanged;
  static UiPreferences of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiScope>()?.notifier?.value ??
      const UiPreferences();
  static void change(BuildContext context, UiPreferences value) =>
      context.getInheritedWidgetOfExactType<UiScope>()?.onChanged(value);
  static Duration duration(BuildContext context, [int ms = 220]) {
    final ui = of(context);
    if (ui.motion == 'reduced' ||
        (ui.followSystem && MediaQuery.disableAnimationsOf(context)))
      return Duration.zero;
    return Duration(
        milliseconds: ui.motion == 'standard' ? (ms * .65).round() : ms);
  }

  static bool loops(BuildContext context) =>
      of(context).motion == 'full' && duration(context) != Duration.zero;
}
