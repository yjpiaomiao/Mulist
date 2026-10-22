# 第三方组件与数据

Mulist 保留以下第三方源码、数据及许可证，便于构建、测试和继续修改。

| 组件 | 来源 | 许可证原文 / 说明 |
| --- | --- | --- |
| TagLib 2.3.2 | https://taglib.org/ · https://github.com/taglib/taglib | `packages/mm_native/third_party/taglib/COPYING.LGPL`、`COPYING.MPL`；本地修改见同目录 `PATCHES.md` |
| utfcpp | https://github.com/nemtrif/utfcpp | `packages/mm_native/third_party/utfcpp/LICENSE`，Boost Software License 1.0 |
| stb_image、stb_image_resize2、stb_image_write | https://github.com/nothings/stb | 相应头文件末尾的 MIT / public domain 许可文本 |
| pinyin-data v0.15.0 | https://github.com/mozillazg/pinyin-data | `tool/data/LICENSE.pinyin-data`，MIT；源数据为 `tool/data/pinyin.txt` |
| media_kit / media_kit_libs_audio | https://github.com/media-kit/media-kit | Dart / Flutter 包为 MIT；版本固定在 `pubspec.lock`，许可证通过 Flutter 许可注册表提供 |
| libmpv 与 FFmpeg 音频库 | https://github.com/media-kit/libmpv-darwin-build · https://mpv.io/ · https://ffmpeg.org/ | 由 media_kit 原生包获取并以动态 framework 打包；各二进制组件许可证以其上游构建配置和发行资料为准，正式分发需一并提供相应许可与源码获取说明 |

`packages/mm_native/third_party/` 中的源码和许可证需一并保留。TagLib 并非未经修改的上游副本，具体差异已记录在 `PATCHES.md`。

Dart、Flutter 与其他包依赖在 `pubspec.yaml` 和 `pubspec.lock` 中声明，通过包管理器获取，其许可证以对应依赖分发的文件为准。系统字体未打包进项目；Noto Sans SC 等字体由运行环境提供。

`packages/mm_native/test/fixtures/` 为测试资源，生成方式见 `packages/mm_native/tool/gen_fixtures.py`。音频使用合成信号，图像使用测试图案；标签文本用于覆盖中文、多值标签和特殊字段行为。
