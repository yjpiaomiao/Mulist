# mm_native

Mulist 的原生音频与文件操作模块。Dart 通过 FFI 调用 C++17 代码，标签读写使用随源码提供的 TagLib 2.3.2。

## 职责

- 读取音频标签、格式信息和内嵌封面，生成封面缩略图。
- 为标签修改生成写入计划，提交前后校验标签与音频数据。
- 保留未修改的标签内容，并在合适的格式中复用已有标签区域。
- 提供文件复制、读写、音频区域校验，以及标签恢复所需的原生接口。
- 支持桌面文件路径与 Android 文件描述符。

此模块提供同步原生调用，应从后台 isolate 调用。Mulist 的操作日志、队列和批量事务协调位于应用的 `lib/core/services/`。

## 目录

```text
lib/mm_native.dart        MmNative、MmTarget 与错误封装
lib/src/bindings.dart     FFI 绑定
hook/build.dart           Dart native assets 编译入口
src/mm_core.h             C ABI
src/tagio.cpp             标签读取、计划生成与提交
src/audio_region.cpp      音频区域定位与校验
src/fsutil.cpp            原生文件操作
src/thumbs.cpp            封面缩略图
src/taglib_config/        TagLib 配置头文件
third_party/              原生依赖源码与许可证
test/                     原生测试与合成资源
tool/gen_fixtures.py      测试资源生成器
```

## 构建与使用

应用根目录的 `pubspec.yaml` 使用路径依赖引用此包。`flutter run`、`flutter test` 和 `flutter build` 会调用构建 hook，无需手动复制 DLL 或单独安装 TagLib。

编译需要目标平台的 C++17 工具链。Windows 使用 MSVC，其他目标使用对应平台的工具链；具体要求见项目根目录 README。

```dart
import 'package:mm_native/mm_native.dart';

// 在后台 isolate 中读取文件，不要阻塞 Flutter UI isolate。
final tags = MmNative.read(const MmTarget.path('/path/to/song.flac'));
```

`MmTarget.fd` 的文件描述符由调用方负责关闭，原生函数不会替调用方关闭。写入操作在应用中通过服务层执行，以保留操作日志和恢复能力。

## 验证

从此包目录运行：

```sh
dart pub get
dart test
```

测试资源是生成的小型音频与图像文件，不包含完整歌曲录音。重新生成需要 ffmpeg、Python 和 `mutagen`：

```sh
python tool/gen_fixtures.py
```

部分测试会在 ffmpeg 可用时进行独立音频包校验。

## 第三方修改

TagLib 的裁剪与标签区域复用修改记录在 [third_party/taglib/PATCHES.md](third_party/taglib/PATCHES.md)。修改第三方源码时保留其许可证、来源和修改记录。其他依赖信息见项目根目录的 [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)。
