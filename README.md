# Aurora

轻量级 Android SSH 终端客户端。

## 页面

1. **首页** — 服务器列表，点击连接
2. **终端** — 交互式 SSH 终端（xterm + dartssh2）
3. **添加 / 编辑服务器**
4. **设置** — 主题、字号、虚拟按键

## 本地运行

需要已安装 Flutter stable 与 Android SDK。


```bash
cd aurora_app
flutter pub get
flutter run
```

### 仅编译 arm64 APK

```bash
flutter build apk --release --target-platform android-arm64
# 产物一般在:
#   build/app/outputs/flutter-apk/app-release.apk
# 或 split:
#   build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

工程已在 `android/app/build.gradle` 中限制 `abiFilters "arm64-v8a"`，不会打出其他 ABI。

## CI

`.github/workflows/build-android-arm64.yml`：

- push / PR / 手动触发时编译 **arm64-v8a** release APK
- 上传 Artifact：`aurora-arm64-v8a-release`
- 打 `v*` tag 时自动创建 GitHub Release

## 包名

- applicationId: `com.aurora.ssh`
- 最低 SDK: Flutter 默认 minSdk（通常 21）

## 权限

- `INTERNET`
- `ACCESS_NETWORK_STATE`

## 功能

- 密码 / 私钥认证
- 虚拟按键（Ctrl / Esc / 方向键 / C-c 等）
- 重连 / 断开
- 本地保存服务器列表
- 主题与终端字号

## 结构

```
lib/
  main.dart
  models/server.dart
  services/   # server_store, settings_store, ssh_session
  pages/      # home, terminal, server_edit, settings
  widgets/    # virt_keys
android/      # 仅 Android 平台
.github/workflows/build-android-arm64.yml
```
