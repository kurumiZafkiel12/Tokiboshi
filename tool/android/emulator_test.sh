#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$RUNNER_TEMP/android-audit"
python3 tool/android/fixture_servers.py --output "$RUNNER_TEMP/android-audit/fixture-events.jsonl" > "$RUNNER_TEMP/android-audit/fixture-server.log" 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
set +e
./android/gradlew -p android :app:connectedDebugAndroidTest -Ptarget-platform=android-x64 --no-daemon > "$RUNNER_TEMP/android-audit/native-tests.log" 2>&1
native_exit=$?
adb logcat -d > "$RUNNER_TEMP/android-audit/logcat.log"
adb pull /sdcard/Android/data/site.kurumizafkiel.tokiboshi/files/ "$RUNNER_TEMP/android-audit/device-files"
tail -100 "$RUNNER_TEMP/android-audit/native-tests.log"
exit "$native_exit"
