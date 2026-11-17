# Android 0.0.9 r2

Android 7.0/API24及以上，arm64-v8a、armeabi-v7a、x86_64。
使用系统VPN授权和前台通知，不需要root。手机布局共用订阅展开、Rust解析/配置、来源隔离、真实控制器、三档动效与导入窗；不使用Windows注册表、托盘或UAC。

## 固定工具链

Flutter3.50.0、FRB2.11.1（本轮无API/codegen改动）、JDK21（构建运行时；应用字节码仍17）、Gradle9.5.0（wrapper校验）、AGP9.3.1、Kotlin2.4.20、NDK28.2.13676358、Go1.25.5、gomobile0.1.12、sing-box/libbox1.14.4固定c005f35300ce76427dc285481ec5695f5b179cd2。Cargokit Android插件使用注入ExecOperations以适配Gradle9；兼容DSL开关保留到FRB后续迁移。Go依赖使用上游go.mod/go.sum，Rust使用Cargo.lock。

```bash
flutter pub get --enforce-lockfile
tool/android/build_libbox.sh
flutter analyze --no-fatal-infos
flutter test --no-pub
flutter build apk --debug --target-platform android-x64 --build-number 11
```

Android SDK需platforms;android-36、build-tools;36.0.0、ndk;28.2.13676358。libbox.aar为生成文件，不入库。默认选择当前物理网络，保护出站socket、防止VPN回环，IPv4/IPv6 TUN与DNS劫持由VpnService建立。

## 验证

android工作流构建内核，再在API35/x86_64模拟器通过Flutter界面真实连接/切换，独立shell UID测试IPv4/IPv6、规则/全局/直连、后台连接、重复启停与UDP DNS；不用应用自身被排除的UID请求充当TUN证据。测试仅使用host回环上的合成SOCKS/HTTP/DNS服务，无真实订阅/凭据。UI支持窄屏/横屏，输入框出现时保留可用连接入口。

三ABI release验证器要求每包仅含目标ABI，并包含Flutter AOT/引擎、Rust及libbox库，校验versionName0.0.9、versionCode1011/2011/4011、同一正式签名、ZIP CRC及64位ELF/ZIP16KiB对齐。CI没有通过之前，不把能编译解释为VPN可用；模拟器不替代所有手机/OEM后台策略验收。

## 发布签名与恢复

正式发布使用稳定RSA3072签名，不发布debug签名APK。若已提供TOKIBOSHI_ANDROID_KEYSTORE_BASE64/STORE_PASSWORD/KEY_PASSWORD/KEY_ALIAS的Actions secrets，恢复既有密钥；首次发行可生成密钥，恢复材料用维护者的公开接收证书AES256-GCM加密。只上传加密备份、公开证书及指纹，私钥和密码不入库/日志/公开APK。已发行版本缺少既有签名时拒绝自动换签。

签名 Secrets 可用时恢复已有密钥；首次正式发行前，必须确认加密恢复备份能在维护者设备解密。当前恢复接收证书由维护者 Windows 设备生成，其私钥只以当前用户 DPAPI 密文保存，不入库。首次发行完成后保存同一签名身份供后续构建使用，禁止换签覆盖。加密备份与公开指纹可归档，但任何私钥、签名密码、解密后的密钥包均不得进入源码或公开日志。

配置android/key.properties后构建：

```bash
flutter build apk --release --split-per-abi --build-name 0.0.9 --build-number 11
python3 tool/android/verify_apks.py
```

发布Android独立tag v0.0.9-android-r1，应用仍对应0.0.9 r2功能，build11。Windows v0.0.9-r2包/tag不改变，其下载页可追加指向Android发行的三APK按钮，源提交分别记录。

## 许可证

Android组合发行按GPL-3.0-or-later，新增安卓接线与完整对应源码公开。上游libbox许可证、固定源码/构建参数以及原有组件版权保存在assets/licenses，并可从应用开源许可证查看。Rust桥接原有MIT OR Apache-2.0声明保留；不修改历史Windows发行包或其他组件授权。


2026-11-18 Codex接续Hermes：保留617cd08起的编译/生命周期修订及Hermes恢复接收证书，CMS备份新增Cloud接收证书，两端任一对应私钥均可恢复；接收证书不是APK签名身份，未替换既有APK签名。DNS探针只放测试APK，app_process校验shell UID2000并直接使用UDP socket，避免netcat启动/EOF行为；DNS响应按记录解析，不假设A记录一定在包末尾。测试改为先构建/安装再直接am instrument，拉取数据后由模拟器销毁清理，避免AGP测试结束卸载先删除诊断。全部成功仍以完整CI和签名恢复实测为准。

恢复备份（只在维护者私有目录操作，输出包含密钥与密码，不提交）：

```bash
python3 tool/android/recover_signing.py --backup Tokiboshi-Android-signing-backup.cms --private-key signing-recovery-private.pem --output-dir /private/new-signing-directory
```

恢复器只接受固定的两个普通文件，校验导出证书指纹后写入私有文件；恢复的key.properties可用于后续同签更新。恢复包/接收私钥不是APK，不得上传公开发行附件。
