import 'dart:io';
import 'dart:convert';
import '../../lib/services/elevated_handoff.dart';
Future<void> main(List<String> args) async {
 await File(args[1]).writeAsString('ready');
 final ok=await waitForParentExit(int.parse(args[0]),timeout:const Duration(seconds:15));
 print(jsonEncode({'parentExited':ok}));
 if(!ok)exitCode=1;
}
