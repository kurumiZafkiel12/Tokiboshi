#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$RUNNER_TEMP/android-audit"
python3 tool/android/fixture_servers.py --output "$RUNNER_TEMP/android-audit/fixture-events.jsonl" > "$RUNNER_TEMP/android-audit/fixture-server.log" 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
./android/gradlew -p android :app:assembleDebug :app:assembleDebugAndroidTest -Ptarget-platform=android-x64 --no-daemon > "$RUNNER_TEMP/android-audit/native-build.log" 2>&1
adb install -r build/app/outputs/apk/debug/app-debug.apk
adb install -r build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
set +e
adb shell am instrument -w -r site.kurumizafkiel.tokiboshi.test/androidx.test.runner.AndroidJUnitRunner > "$RUNNER_TEMP/android-audit/native-tests.log" 2>&1
instrument_exit=$?
adb logcat -d > "$RUNNER_TEMP/android-audit/logcat.log"
adb pull /sdcard/Android/data/site.kurumizafkiel.tokiboshi/files/ "$RUNNER_TEMP/android-audit/device-files"
cat "$RUNNER_TEMP/android-audit/native-tests.log"
# am instrument may exit zero even on JUnit failure. Require explicit success.
if [ "$instrument_exit" -ne 0 ] || ! rg -q 'OK \(1 test\)' "$RUNNER_TEMP/android-audit/native-tests.log"; then
  exit 1
fi
