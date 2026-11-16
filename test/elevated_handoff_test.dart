import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokiboshi/services/elevated_handoff.dart';
void main() {
 test('handoff waits for actual exit and rejects failure/timeout',()async{
  var calls=0;
  expect(await waitForParentExit(pid+1,interval:Duration.zero,probe:()=>++calls<3?258:0),true);
  expect(calls,3);
  expect(await waitForParentExit(pid+1,probe:()=>0xffffffff),false);
  expect(await waitForParentExit(pid+1,timeout:Duration.zero,probe:()=>258),false);
  expect(await waitForParentExit(pid,probe:()=>0),false);
 });
}
