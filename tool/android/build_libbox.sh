#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
core_source="${TOKIBOSHI_SING_BOX_SOURCE:-$project_root/build/android-deps/sing-box}"
core_commit=c005f35300ce76427dc285481ec5695f5b179cd2
if [ ! -d "$core_source/.git" ]; then
  git clone --depth 1 --branch v1.14.4 https://github.com/SagerNet/sing-box.git "$core_source"
fi
[ "$(git -C "$core_source" rev-parse HEAD)" = "$core_commit" ] || { echo 'Unexpected sing-box source'; exit 1; }
[ -z "$(git -C "$core_source" status --porcelain)" ] || { echo 'Modified sing-box source'; exit 1; }
export GOBIN="${GOBIN:-$project_root/build/android-deps/go-bin}"
mkdir -p "$GOBIN" "$project_root/android/app/libs"
export PATH="$GOBIN:$PATH"
export ANDROID_HOME="${ANDROID_HOME:?Android SDK required}"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export GOFLAGS="${GOFLAGS:--p=4}"
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
cd "$core_source"
gomobile init
gomobile bind -target=android/arm64,android/arm,android/amd64 -androidapi=24 \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_low_memory \
  -ldflags='-s -w -buildid= -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=1.14.4' \
  -o "$project_root/android/app/libs/libbox.aar" ./experimental/libbox
