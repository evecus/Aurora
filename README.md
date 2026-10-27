# Aurora

轻量级 Android SSH 终端客户端。

## 页面

1. **首页** — 服务器列表，点击连接（可通过设置追加「本机」「Linux」入口）
2. **终端** — 交互式 SSH 终端（xterm + dartssh2），本机 / Linux 复用同一页
3. **添加 / 编辑服务器**
4. **设置** — 主题、字号、虚拟按键、本机终端、Linux 终端

## 本地 Linux 终端（proot）

设置里打开 **启用 Linux 终端** 后，首页多出一个 `Linux` 条目，点进去就是
Alpine 3.22.5 的 shell。全部使用默认值，没有配置入口：

| 项 | 默认值 |
|---|---|
| 发行版 / 版本 | Alpine 3.22.5 minirootfs（aarch64） |
| 镜像 | `https://dl-cdn.alpinelinux.org` |
| DNS | `1.1.1.1`、`8.8.8.8` |
| rootfs 位置 | 应用 files 目录 `linux/rootfs` |

- 打开开关即部署（下载 → 解压 → 写 `resolv.conf` / `apk/repositories` / `hosts`），设置页显示进度与占用；
- 关闭开关即清理 rootfs；另有「重新部署 / 清理 rootfs」；
- 终端页在未部署时会自动部署，失败可重试；
- proot 环境**不是容器**：无内核隔离，`-0` 只是 fake root，ptrace 有性能损耗。

### proot 二进制（不进仓库，构建时生成）

需要两个文件，都放在 `android/app/src/main/jniLibs/arm64-v8a/`：

| 文件 | 作用 |
|---|---|
| `libproot.so` | proot 本体 |
| `libproot-loader.so` | proot 的 loader，运行时通过 `PROOT_LOADER` 指过去 |

targetSdk ≥ 29 不允许 exec 应用私有目录里的文件，而 rootfs 全在那里。proot
不用 execve 执行 guest 二进制，而是用自带 loader 映射 guest ELF —— 所以 loader
自己必须可执行，只能是 nativeLibraryDir（`apk_data_file`）。配套要求：

- `android/app/build.gradle`：`packaging.jniLibs.useLegacyPackaging = true`
- `AndroidManifest.xml`：`android:extractNativeLibs="true"`

（minSdk ≥ 23 时原生库默认不解包，不开这两项 `nativeLibraryDir` 根本不存在。）

生成方式（需要 NDK）：

```bash
scripts/build-proot-android.sh            # 输出到 jniLibs/arm64-v8a/
scripts/build-proot-android.sh --clean    # 清理
```

脚本锁定了 `termux/proot` 的 `v5.1.107.90`（tag + commit）与 talloc 2.4.2，
用 NDK 的 `aarch64-linux-android26-clang` 编译。仓库里**不含**编译产物：
没有这两个 so 时，Linux 入口会提示缺少 proot，其余功能不受影响。

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
- 本机终端（`/system/bin/sh`）与本机 Linux 终端（proot + Alpine）

## 结构

```
lib/
  main.dart
  models/server.dart
  services/   # server_store, settings_store, ssh_session,
              # local_session, linux_env, linux_session
  pages/      # home, terminal, server_edit, settings
  widgets/    # virt_keys
android/app/src/main/jniLibs/arm64-v8a/   # libproot.so + libproot-loader.so（构建产物）
scripts/build-proot-android.sh            # NDK 编译 proot
android/      # 仅 Android 平台
.github/workflows/build-android-arm64.yml
```
