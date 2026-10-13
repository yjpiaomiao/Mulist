# Mulist

**本地音乐管理工具：整理曲库、编辑标签、管理歌单和批量重命名。**

Mulist 使用 Flutter 构建界面，Dart 后台 isolate 处理扫描、搜索和操作队列，C++ 原生模块通过 TagLib 读写音频元数据。应用无需账号，音乐文件、索引与操作记录均保存在本机。

当前版本为 `0.1.0+1`。本仓库提供源码、构建配置和测试资源，暂不提供发行版。

## 功能

| 功能 | 说明 |
| --- | --- |
| 曲库扫描 | 添加多个文件夹，按文件大小和修改时间增量扫描，支持完整重扫、取消扫描及缺失文件识别 |
| 浏览与搜索 | 列表、封面网格和详情面板；支持排序、中文子串、拼音全拼/首字母，以及字段限定查询 |
| 标签编辑 | 单曲与批量编辑标题、艺术家、专辑、曲目号等标签，查看原始标签，替换、提取或移除封面 |
| 歌单管理 | 创建、重命名和删除歌单；导出 TXT、M3U、M3U8，支持相对/绝对路径及换行符等选项 |
| 批量重命名 | 基于标签生成文件名与目录，执行前预览，处理重名、非法字符和路径问题，跟随处理同名伴随文件 |
| 操作历史 | 标签写入和重命名记录操作日志，提供撤销、失败项重试和启动恢复机制 |
| 界面 | 简体中文/英文、系统浅色/深色主题，以及桌面、窄窗口和手机布局 |

当前功能侧重音乐文件管理，尚未实现内置播放、在线标签匹配或云同步。

### 音频格式

扫描器识别以下扩展名：

```text
mp3 mp2 flac m4a m4b mp4 aac alac
ogg oga opus spx wav aif aiff aifc
ape wv mpc tta wma asf dsf dff
```

实际解析、标签字段和封面支持由文件的容器、标签类型及 TagLib 实现决定；扩展名在列表中不代表每个变体都支持同样的编辑操作。

## 平台

| 平台 | 状态与文件访问方式 |
| --- | --- |
| Windows | 已在本地完成构建及界面测试；直接访问文件路径 |
| macOS | 已包含 Runner 和安全域书签实现，需要在 macOS 上验证构建与运行 |
| Android | 已包含 Runner 和 Kotlin SAF 存储实现，通过系统文件选择器获取目录权限，需要在 Android 环境验证 |
| Linux | 已包含 Runner 和桌面路径后端，需要在 Linux 上验证构建与运行 |

当前没有 iOS 或 Web 工程。Android 的存储提供方可能对路径、改名和目录访问施加额外限制；macOS 使用用户授予的文件夹访问权限。

## 开发环境

- Flutter stable：需附带 **Dart 3.13.5 或更高的兼容 3.x 版本**，以 `pubspec.yaml` 中的 SDK 约束为准。
- Git。
- 目标平台对应的构建工具。原生模块使用 C++17，由 Dart native assets 的构建 hook 编译。

| 目标平台 | 所需工具 |
| --- | --- |
| Windows | Visual Studio 2022 的“使用 C++ 的桌面开发”工作负载、Windows SDK、MSVC 与 CMake |
| macOS | Xcode、命令行工具；按 Flutter 环境诊断补齐所需组件 |
| Android | Android SDK、JDK 17、NDK 和 CMake；Gradle Wrapper 配置位于 `android/gradle/wrapper/` |
| Linux | C++ 编译器、CMake、Ninja、pkg-config、GTK 3 开发依赖，以及 Flutter 要求的系统开发包 |

第三方 C++ 源码已包含在 `packages/mm_native/third_party/`，无需另外安装 TagLib。构建首次解析 Dart、Gradle 等依赖时需要网络；应用的音乐管理功能在本地运行。

### 获取并运行

```powershell
git clone git@github.com:yjpiaomiao/Mulist.git
cd Mulist
flutter doctor -v
flutter pub get
flutter run -d windows
```

macOS、Linux 使用相应的设备标识；Android 先连接设备或启动模拟器，再通过 `flutter devices` 查询设备并运行。

项目根目录就是 Flutter 应用根目录，无需再进入额外的 `music_manager/` 子目录。内部 Dart 包名仍为 `music_manager`，包导入使用 `package:music_manager/...`。

### 本地构建

```powershell
flutter build windows --release
```

Windows 输出位于 `build/windows/x64/runner/Release/Mulist.exe`。运行时需保持同目录的原生 DLL 与 `data/` 文件夹完整。

其他平台的本地构建命令：

```sh
flutter build macos --release
flutter build linux --release
flutter build apk --release
```

当前 Android release 配置使用开发调试签名。正式分发前需要自行配置签名；本仓库不包含签名密钥，也没有自动发布发行版的工作流。

## 使用说明

1. 在“设置”中添加音乐文件夹，等待首次扫描完成。
2. 从“全部曲目”、文件夹或歌单切换曲目来源，选择列表或封面视图。
3. 搜索或选中曲目后，查看详情、编辑标签、加入歌单或导出。
4. 批量重命名时先调整模板和冲突处理方式，检查预览后执行。模板包含子目录时需选择目标文件夹。
5. 通过“操作历史”检查结果、撤销操作或重试失败项。

从曲库移除曲目或文件夹不会删除磁盘上的音乐文件。标签编辑和重命名会修改文件；设置中可启用整文件备份、保留修改时间，并调整并发数等选项。

### 搜索示例

```text
周杰伦
zhoujielun
zjl
artist:周杰伦 album:叶惠美
title:晴天
file:flac
```

空格分隔的多个条件需要同时满足。可限定 `title`、`artist`、`album`、`albumartist`、`composer`、`genre`、`file` 字段，也支持代码中定义的中文字段名和简写。

### 重命名模板

```text
{artist} - {title}.{ext}
{albumartist|artist}/{album}/[{disc}-]{track:2} {title}.{ext}
```

| 语法 | 含义 |
| --- | --- |
| `{title}`、`{album}` | 插入对应标签字段 |
| `{track:2}` | 将曲目号补零为两位 |
| `{albumartist|artist|未知}` | 依次选择非空字段，最后使用字面文本 |
| `[{disc}-]` | 可选片段，字段为空时省略 |
| `/` | 创建目录层级 |

标签里的路径分隔符不会直接生成目录。模板引擎会净化字段值和最终路径，并在预览中标出缺失字段、重名和路径等问题。

### 桌面快捷键

| Windows / Linux | macOS | 操作 |
| --- | --- | --- |
| `Ctrl+F` | `Cmd+F` | 聚焦搜索 |
| `Ctrl+A` | `Cmd+A` | 全选当前结果 |
| `Ctrl+E` | `Cmd+E` | 编辑所选曲目的标签 |
| `Ctrl+Z` | `Cmd+Z` | 撤销上一次操作 |
| `F2` | `F2` | 批量重命名 |
| `Space` | `Space` | 切换详情面板 |
| `Delete` | `Delete` | 从曲库移除所选曲目 |
| `↑` / `↓`、`Shift+↑` / `Shift+↓` | 同左 | 移动焦点或连续选择 |

文本输入时，部分全局快捷键会让位于输入框。

## 字体与本地数据

Windows 界面主字体为 **Noto Sans SC**，使用系统中已安装的字体；未安装或字符未覆盖时，候补顺序为 Microsoft YaHei UI、Microsoft YaHei、Segoe UI。字体不随仓库或应用打包。macOS 和 Android 使用对应平台的系统字体配置。

Windows 数据目录保留原来的存储标识，与产品名称 Mulist 分离：

```text
%APPDATA%/io.github.musicmanager/music_manager/
  library.db     曲库、设置、歌单与操作记录
  backups/       操作备份
  stage/         操作暂存

%LOCALAPPDATA%/io.github.musicmanager/music_manager/
  thumbs/        封面缩略图缓存
```

其他平台由 `path_provider` 提供应用支持目录与缓存目录。用户音乐、数据库、缓存及备份不进入版本控制。

## 源码结构

```text
Mulist/
├── lib/
│   ├── main.dart              应用入口
│   ├── app/                   应用状态、布局、主题、语言与平台交互
│   ├── core/
│   │   ├── db/                SQLite 表结构与数据访问
│   │   ├── model/             曲目、目录与标签数据模型
│   │   ├── scan/              后台扫描与增量更新
│   │   ├── search/            搜索索引、排序与搜索 isolate
│   │   ├── pinyin/            拼音检索与生成后的查询表
│   │   ├── storage/           桌面路径、Windows 快捷方式与 Android SAF
│   │   ├── path/              路径身份与文件名净化
│   │   ├── template/          重命名模板解析与渲染
│   │   ├── jobs/              原生工作 isolate 池
│   │   └── services/          标签写入、重命名、歌单与操作恢复
│   └── features/              曲库、详情、编辑、歌单、重命名、历史与设置
├── packages/mm_native/
│   ├── lib/                   Dart FFI 接口与绑定
│   ├── hook/build.dart        原生编译 hook
│   ├── src/                   C++ 标签、音频校验、文件操作与缩略图代码
│   ├── third_party/           TagLib、utfcpp 与 stb 源码和许可证
│   ├── test/                  原生测试与小型合成音频测试资源
│   └── tool/                  测试资源生成脚本
├── android/ linux/ macos/ windows/  平台 Runner 与构建配置
├── test/                      核心逻辑、服务、界面、基准与开发辅助测试
├── tool/                      拼音表与合成曲库生成工具
├── pubspec.yaml               应用依赖与 SDK 约束
├── pubspec.lock               固定应用依赖版本
└── THIRD_PARTY_NOTICES.md      第三方来源与许可证位置
```

界面通过应用状态调用后台服务。扫描、数据库与搜索分别在后台 isolate 中执行，原生池负责调用 `mm_native`。SQLite 启用 WAL；文件写入流程通过操作日志衔接预备计划、提交、撤销和恢复。

修改界面通常从 `lib/features/` 与 `lib/app/` 入手；修改检索、模板或存储规则从 `lib/core/` 入手；修改音频标签或校验逻辑从 `packages/mm_native/src/` 入手。模块 README 见 [mm_native](packages/mm_native/README.md)。

## 测试与开发工具

在项目根目录运行：

```powershell
flutter analyze
flutter test
```

独立验证原生模块：

```powershell
cd packages/mm_native
dart pub get
dart test
```

界面测试 `test/ui/screens_test.dart` 会生成 `build/screens/` 下的截图，覆盖主要页面、窗口尺寸和深色主题。Windows 上会尝试加载本机的 Noto Sans SC 等字体；其他环境需配置字体后再比较视觉效果。

部分基准与开发辅助测试默认跳过，需显式提供环境变量。示例：

```powershell
dart run tool/gen_library.dart build/synthetic_library 10000
$env:MM_BENCH_LIB = (Resolve-Path build/synthetic_library).Path
flutter test test/bench/bench_test.dart
Remove-Item Env:MM_BENCH_LIB
```

`test/tool/seed_app_test.dart` 会写入 `MM_APP_DATA` 指定的数据库，供本机手动测试使用；常规测试不需要启用。

- `dart run tool/gen_pinyin.dart`：从 `tool/data/pinyin.txt` 重新生成拼音查询表。
- `packages/mm_native/tool/gen_fixtures.py`：生成小型音频测试资源，需要 Python、`mutagen` 和 ffmpeg。现有测试资源已纳入仓库，普通构建无需重新生成。
- 安装 ffmpeg 后，部分原生测试还会使用独立的音频包校验；未安装时相应外部校验会跳过。

## 版本控制约定

提交应用源码、平台构建配置、依赖锁文件、必要图标与合成测试资源，以及本 README 和第三方许可证。`build/`、`dist/`、缓存、IDE 本机配置、数据库、凭据、AI 指令和交接文档均由 `.gitignore` 排除。

本机保留的历史目录和工作笔记放在 `.local/`，不属于仓库内容。提交前可以用以下命令检查范围：

```powershell
git status --short
git diff --cached --stat
```

## 第三方与许可证

第三方 C++ 组件和拼音数据的来源、许可证及本地修改说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。其许可证原文保留在相应源码目录中。

项目自有代码目前未指定开源许可证。
