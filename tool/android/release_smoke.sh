#!/usr/bin/env bash
set -euo pipefail
smoke_dir="$RUNNER_TEMP/release-smoke"
mkdir -p "$smoke_dir"
adb install -r "$RUNNER_TEMP/packages/Tokiboshi-0.0.9-android-x86_64.apk" | tee "$smoke_dir/install.log"
adb shell am start -W -n site.kurumizafkiel.tokiboshi/.MainActivity | tee "$smoke_dir/launch.log"
for attempt in $(seq 1 10); do
  adb shell uiautomator dump /sdcard/release-window.xml > /dev/null
  adb pull /sdcard/release-window.xml "$smoke_dir/ui.xml" > /dev/null
  if grep -q 'VPN 未连接' "$smoke_dir/ui.xml"; then break; fi
  sleep 2
done
adb shell pidof site.kurumizafkiel.tokiboshi > "$smoke_dir/pid.txt"
app_pid=$(tr -d '\r\n' < "$smoke_dir/pid.txt")
test -n "$app_pid"
adb logcat -d --pid="$app_pid" > "$smoke_dir/app-logcat.log"
adb shell dumpsys package site.kurumizafkiel.tokiboshi > "$smoke_dir/package.txt"
adb exec-out screencap -p > "$smoke_dir/signed-release-home.png"
python3 - <<'PY'
import json,os,pathlib,xml.etree.ElementTree as ET
root=pathlib.Path(os.environ['RUNNER_TEMP'])/'release-smoke'
text=' '.join(n.get('text','')+' '+n.get('content-desc','') for n in ET.parse(root/'ui.xml').iter())
for label in ['Tokiboshi','VPN 未连接','启动 VPN','订阅','设置']:assert label in text,label
package=(root/'package.txt').read_text();assert 'versionCode=4011' in package and 'versionName=0.0.9' in package
logs=(root/'app-logcat.log').read_text();assert 'FATAL EXCEPTION' not in logs and 'Fatal signal' not in logs
(root/'result.json').write_text(json.dumps({'source':'9aa0c3bc60906130d9f52b7dfd9109bd91fef8c5','buildRun':44119946722,'signedReleaseInstalled':True,'aotFlutterHomeRendered':True,'versionCode':4011,'passed':True},indent=2)+'\n')
print('Signed release APK installed and actual AOT Flutter interface rendered.')
PY
