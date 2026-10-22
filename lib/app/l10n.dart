// UI strings (Simplified Chinese / English).
import 'package:flutter/widgets.dart';

class S {
  final bool zh;
  const S(this.zh);

  static S of(BuildContext context) => Localizations.of<S>(context, S) ?? const S(false);

  String _(String zhText, String en) => zh ? zhText : en;

  // playback
  String get play => _('播放', 'Play');
  String get pause => _('暂停', 'Pause');
  String get previousTrack => _('上一首', 'Previous');
  String get nextTrack => _('下一首', 'Next');
  String get stopPlayback => _('停止播放', 'Stop');
  String get nowPlaying => _('正在播放', 'Now playing');
  String get chooseToPlay => _('选择一首音乐，开始聆听', 'Choose a track to start listening');
  String get playHint => _('双击曲目播放 · 空格暂停', 'Double-click to play · Space to pause');
  String get queue => _('播放队列', 'Play queue');
  String get shuffle => _('随机播放', 'Shuffle');
  String get repeatOff => _('顺序播放', 'Repeat off');
  String get repeatAll => _('列表循环', 'Repeat all');
  String get repeatOne => _('单曲循环', 'Repeat one');
  String get volume => _('音量', 'Volume');
  String get outputSettings => _('音频输出', 'Audio output');
  String get sourceAudio => _('源文件', 'Source');
  String get actualOutput => _('引擎输出', 'Engine output');
  String get waitingOutput => _('播放后显示实际输出参数', 'Output parameters appear during playback');
  String get sharedOutput => _('标准输出', 'Shared output');
  String get exclusiveOutput => _('跟随音源 · 独占输出', 'Follow source · Exclusive output');
  String get exclusiveHint => _(
    '尝试按音源规格打开音频设备，并保持应用音量为 100%。设备将由本程序独占，可能暂停其他应用的声音。',
    'Requests the source format with app volume fixed at 100%. Takes exclusive device access and may silence other apps.',
  );
  String get qualityHint => _(
    '直接解码原文件，不做有损转码、均衡或响度归一化。最终采样率、位深与声道受输出设备支持范围限制；蓝牙及系统混音可能转换音频。DSD 解码为 PCM，不承诺 DSD 直通或逐位一致。',
    'Decodes the original file without lossy transcoding, EQ or normalization. Final sample rate, bit depth and channels depend on the device; Bluetooth and the system mixer may convert audio. DSD is decoded to PCM; DSD passthrough and bit-perfect output are not guaranteed.',
  );
  String get outputDevice => _('输出设备', 'Output device');
  String get systemDefault => _('系统默认', 'System default');
  String get outputMismatch => _('设备输出与音源采样率不同', 'Output sample rate differs from the source');
  String get exclusiveVolume =>
      _('独占模式固定 100% 音量，请使用设备控制音量', 'Exclusive mode uses 100% app volume; use device volume controls');
  String get playbackFailed =>
      _('无法播放此文件，请检查文件权限、格式或输出设备。', 'Unable to play. Check file access, format or output device.');
  String get playbackPathUnavailable =>
      _('文件已移除或此存储位置暂不支持播放。', 'The file was removed or this storage location does not support playback.');
  String get seekPlayback => _('播放进度', 'Seek');

  // navigation
  String get appName => 'Mulist';
  String get library => _('曲库', 'Library');
  String get allTracks => _('全部曲目', 'All tracks');
  String get folders => _('文件夹', 'Folders');
  String get playlists => _('歌单', 'Playlists');
  String get history => _('操作历史', 'History');
  String get settings => _('设置', 'Settings');
  String get tasks => _('任务', 'Tasks');
  String get addFolder => _('添加文件夹', 'Add folder');
  String get newPlaylist => _('新建歌单', 'New playlist');

  // library
  String get search => _('搜索标题、艺术家、专辑、文件名或拼音', 'Search title, artist, album, file name');
  String get searchShort => _('搜索', 'Search');
  String get listView => _('列表', 'List');
  String get gridView => _('封面', 'Covers');
  String get sortBy => _('排序', 'Sort');
  String tracksCount(int n) => _('$n 首', '$n tracks');
  String selectedCount(int n) => _('已选 $n 首', '$n selected');
  String outsideView(int n) => _('另有 $n 首已选曲目不在当前结果中', '$n more selected tracks are not in this view');
  String get emptyLibrary => _('还没有曲目。添加一个文件夹开始吧。', 'No tracks yet. Add a folder to get started.');
  String get noResults => _('没有匹配的曲目', 'No matching tracks');
  String get rescan => _('重新扫描', 'Rescan');
  String get fullRescan => _('完整重新扫描', 'Full rescan');
  String get removeFolder => _('从曲库移除文件夹', 'Remove folder from library');
  String removeFolderConfirm(String p) =>
      _('从曲库移除“$p”？磁盘上的文件不会被删除。', 'Remove "$p" from the library? Files on disk are not deleted.');
  String scanning(int parsed, int total, int found) =>
      _('正在扫描 $parsed/$total（已发现 $found）', 'Scanning $parsed/$total ($found found)');
  String scanDone(int found, int added, int updated, int failed, int missing, double secs) => _(
      '扫描完成：$found 个文件，新增 $added，更新 $updated，无法读取 $failed，缺失 $missing（${secs.toStringAsFixed(1)} 秒）',
      'Scan finished: $found files, $added new, $updated updated, $failed unreadable, $missing missing (${secs.toStringAsFixed(1)} s)');
  String get scanCancelled => _('扫描已取消', 'Scan cancelled');
  String get selectAll => _('全选', 'Select all');
  String get clearSelection => _('取消选择', 'Clear selection');
  String get cancel => _('取消', 'Cancel');
  String get ok => _('确定', 'OK');
  String get close => _('关闭', 'Close');
  String get save => _('保存', 'Save');
  String get apply => _('应用', 'Apply');
  String get delete => _('删除', 'Delete');
  String get rename => _('重命名', 'Rename');
  String get edit => _('编辑', 'Edit');
  String get editTags => _('编辑标签', 'Edit tags');
  String get renameFiles => _('批量重命名', 'Rename files');
  String get addToPlaylist => _('加入歌单', 'Add to playlist');
  String get export => _('导出', 'Export');
  String get exportPlaylist => _('导出歌单', 'Export playlist');
  String get revealInFiles => _('在文件管理器中显示', 'Show in file manager');
  String get copyPath => _('复制路径', 'Copy path');
  String get removeFromLibrary => _('从曲库移除', 'Remove from library');
  String removeTracksConfirm(int n) =>
      _('从曲库移除 $n 首曲目？磁盘上的文件不会被删除，重新扫描会再次加入。', 'Remove $n tracks from the library? Files stay on disk; a rescan adds them again.');
  String get undo => _('撤销', 'Undo');
  String get undoLast => _('撤销上一个操作', 'Undo last operation');
  String get details => _('详情', 'Details');
  String get missingFile => _('文件缺失', 'File missing');
  String get unreadable => _('无法读取', 'Unreadable');
  String get selectMode => _('选择', 'Select');
  String get more => _('更多', 'More');
  String get removeMissing => _('移除缺失的曲目', 'Remove missing tracks');

  // columns / fields
  String get title => _('标题', 'Title');
  String get artist => _('艺术家', 'Artist');
  String get album => _('专辑', 'Album');
  String get albumArtist => _('专辑艺术家', 'Album artist');
  String get trackNo => _('曲目号', 'Track');
  String get discNo => _('碟号', 'Disc');
  String get year => _('年份', 'Year');
  String get genre => _('流派', 'Genre');
  String get composer => _('作曲', 'Composer');
  String get comment => _('备注', 'Comment');
  String get duration => _('时长', 'Duration');
  String get format => _('格式', 'Format');
  String get path => _('路径', 'Path');
  String get added => _('添加时间', 'Date added');
  String get cover => _('封面', 'Cover');

  // detail
  String get tags => _('标签', 'Tags');
  String get formatInfo => _('格式信息', 'Format');
  String get container => _('容器', 'Container');
  String get codec => _('编码', 'Codec');
  String get bitrate => _('码率', 'Bitrate');
  String get sampleRate => _('采样率', 'Sample rate');
  String get channels => _('声道', 'Channels');
  String get bitDepth => _('位深', 'Bit depth');
  String get tagFormats => _('标签格式', 'Tag formats');
  String get fileSize => _('文件大小', 'File size');
  String get filePath => _('文件路径', 'File path');
  String get allRawTags => _('全部原始标签', 'All raw tags');
  String get noCover => _('无内嵌封面', 'No embedded cover');
  String get pictures => _('图片', 'Pictures');
  String get selectTrackHint => _('选择一首曲目查看详情', 'Select a track to see its details');
  String nSelectedDetail(int n) => _('已选 $n 首曲目', '$n tracks selected');

  // editor
  String get multipleValues => _('（多个值）', '(multiple values)');
  String get keepCover => _('保持封面', 'Keep cover');
  String get replaceCover => _('替换封面…', 'Replace cover…');
  String get removeCover => _('移除封面', 'Remove cover');
  String editingN(int n) => _('编辑 $n 首曲目', 'Editing $n tracks');
  String get onlyChangedWritten => _('只有改动过的字段会被写入，其余标签保持不变。', 'Only fields you change are written; everything else is kept.');
  String separatorHint(String s) => _('多个值用“$s”分隔', 'Separate multiple values with "$s"');
  String get revert => _('还原', 'Revert');
  String get writing => _('正在写入标签', 'Writing tags');

  // jobs
  String jobSummary(int ok, int skipped, int failed) =>
      _('成功 $ok · 跳过 $skipped · 失败 $failed', '$ok succeeded · $skipped skipped · $failed failed');
  String get retryFailed => _('重试失败项', 'Retry failed');
  String get showDetails => _('查看详情', 'Details');
  String get jobTagWrite => _('写入标签', 'Writing tags');
  String get jobRename => _('重命名', 'Renaming');
  String get jobUndo => _('撤销', 'Undoing');
  String get jobExport => _('导出', 'Exporting');
  String get failedItems => _('失败的项目', 'Failed items');
  String get skippedItems => _('跳过的项目', 'Skipped items');
  String get nothingToUndo => _('没有可撤销的操作', 'Nothing to undo');

  // rename
  String get template => _('模板', 'Template');
  String get templateHelp => _(
      '变量：{title} {artist} {album} {albumartist} {track} {disc} {year} {genre} {composer} {ext} {filename}\n'
          '{track:2} 补零 · {albumartist|artist|未知} 依次回退 · [{disc}-] 可选段 · / 分目录',
      'Variables: {title} {artist} {album} {albumartist} {track} {disc} {year} {genre} {composer} {ext} {filename}\n'
          '{track:2} zero pad · {albumartist|artist|Unknown} fallback · [{disc}-] optional · / folders');
  String get targetFolder => _('目标文件夹', 'Target folder');
  String get chooseTarget => _('选择目标文件夹…', 'Choose target folder…');
  String get targetRequired => _('模板包含子目录，请选择目标文件夹', 'The template creates folders: choose a target folder');
  String get targetAdded => _('目标文件夹不在曲库中，已自动添加为曲库文件夹', 'The target folder was added to the library');
  String get conflictPolicy => _('重名时', 'On conflict');
  String get autoNumber => _('自动编号', 'Number them');
  String get skipConflict => _('跳过', 'Skip');
  String get onlyProblems => _('只看有问题的', 'Only problems');
  String previewSummary(int change, int unchanged, int problems, int ms) => _(
      '$change 个将改名 · $unchanged 个无变化 · $problems 个有问题 · 预览用时 $ms ms',
      '$change to rename · $unchanged unchanged · $problems with issues · preview $ms ms');
  String get flagUnchanged => _('无变化', 'Unchanged');
  String get flagSanitized => _('已净化', 'Sanitized');
  String get flagConflict => _('冲突', 'Conflict');
  String get flagNumbered => _('已编号', 'Numbered');
  String get flagLongPath => _('路径过长', 'Path too long');
  String get flagMissing => _('缺少字段', 'Missing fields');
  String get flagExt => _('扩展名改变', 'Extension changed');
  String get flagManual => _('手动修改', 'Edited');
  String get execute => _('执行', 'Run');
  String get companionsNote => _('同名的 .lrc / .cue / 图片等伴随文件会一起改名或移动。', 'Companion files with the same name (.lrc, .cue, images…) are renamed along.');
  String get removeEmptyDirs => _('移动后删除空文件夹', 'Remove folders left empty');

  // playlists
  String get playlistName => _('歌单名称', 'Playlist name');
  String get createFromSelection => _('用所选曲目新建歌单', 'New playlist from selection');
  String get deletePlaylist => _('删除歌单', 'Delete playlist');
  String deletePlaylistConfirm(String n) => _('删除歌单“$n”？曲目文件不受影响。', 'Delete playlist "$n"? Tracks are not affected.');
  String get renamePlaylist => _('重命名歌单', 'Rename playlist');
  String get removeFromPlaylist => _('从歌单移除', 'Remove from playlist');
  String addedToPlaylist(int n, String p) => _('已将 $n 首加入“$p”', 'Added $n tracks to "$p"');
  String get noPlaylists => _('还没有歌单', 'No playlists yet');

  // export
  String get exportFormat => _('格式', 'Format');
  String get plainText => _('纯文本（艺术家 - 标题）', 'Plain text (Artist - Title)');
  String get pathMode => _('路径', 'Paths');
  String get relativePaths => _('相对路径', 'Relative');
  String get absolutePaths => _('绝对路径', 'Absolute');
  String get baseDir => _('相对路径基准目录', 'Base folder for relative paths');
  String get baseDirDefault => _('默认：歌单文件所在目录', 'Default: folder of the playlist file');
  String get chooseBaseDir => _('选择…', 'Choose…');
  String get pathSeparator => _('路径分隔符', 'Path separator');
  String get lineEnding => _('换行符', 'Line endings');
  String get extInfo => _('写入 #EXTINF 信息', 'Write #EXTINF info');
  String get utf8Bom => _('UTF-8 带 BOM（便于旧播放器识别中文）', 'UTF-8 with BOM (helps older players)');
  String exported(int n, String p) => _('已导出 $n 首到 $p', 'Exported $n tracks to $p');
  String exportProblems(int n) => _('$n 首无法写入', '$n tracks could not be written');
  String get problemNoAbsolute => _('无法推导绝对路径，请改用相对路径', 'No absolute path: use relative paths');
  String get problemNoRelative => _('无法计算相对路径（不同磁盘？）', 'No relative path (different drive?)');

  // history
  String get noHistory => _('还没有操作记录', 'No operations yet');
  String get kindTagWrite => _('写入标签', 'Tag write');
  String get kindRename => _('重命名', 'Rename');
  String get kindUndo => _('撤销', 'Undo');
  String get stateDone => _('完成', 'Done');
  String get statePartial => _('部分完成', 'Partly done');
  String get stateFailed => _('失败', 'Failed');
  String get stateUndone => _('已撤销', 'Undone');
  String get stateRunning => _('进行中', 'Running');
  String get stateSkipped => _('无改动', 'No changes');
  String get clearHistory => _('清空历史与备份', 'Clear history and backups');
  String get clearHistoryConfirm => _('清空后将无法撤销这些操作。继续？', 'Operations can no longer be undone afterwards. Continue?');
  String get undoConfirm => _('撤销此操作？', 'Undo this operation?');

  // settings
  String get language => _('语言', 'Language');
  String get followSystem => _('跟随系统', 'System');
  String get multiSeparator => _('多值分隔符', 'Multi-value separator');
  String get keepMtime => _('保留文件修改时间', 'Keep file modification time');
  String get wholeFileBackup => _('写入前整文件备份', 'Back up whole files before writing');
  String get wholeFileBackupHint => _('默认只备份被修改的标签区域；整文件备份会占用更多磁盘空间（超过上限自动清理最旧的）。',
      'By default only the changed tag area is backed up; whole-file backups use more space (oldest are removed above the limit).');
  String get backupLimit => _('整文件备份上限（MB）', 'Whole-file backup limit (MB)');
  String get ioConcurrency => _('同时写入的文件数', 'Files written in parallel');
  String get illegalChars => _('文件名非法字符替换为', 'Replace illegal file name characters with');
  String get fullWidthChars => _('全角字符（：？＊）', 'Full-width look-alikes (：？＊)');
  String get underscore => _('下划线 _', 'Underscore _');
  String get about => _('关于', 'About');
  String get aboutText => _('纯本地音乐管理工具，不联网、无账号。标签读写基于 TagLib。', 'A local music manager. No network, no account. Tags by TagLib.');
  String get rootsSection => _('曲库文件夹', 'Library folders');
  String lastScan(String t) => _('上次扫描：$t', 'Last scan: $t');
  String get neverScanned => _('尚未扫描', 'Not scanned yet');
  String get androidPickerNote => _('提示：系统选择器不能选择存储根目录和 Download 根目录，请选择其中的子文件夹。',
      'Note: the system picker cannot select the storage root or the Download folder itself; choose a folder inside.');

  // errors
  String error(String code) => switch (code) {
        'file_in_use' => _('文件被其他程序占用', 'File is in use by another program'),
        'access_denied' => _('没有权限', 'Access denied'),
        'not_found' => _('文件不存在', 'File not found'),
        'disk_full' => _('磁盘已满', 'Disk full'),
        'file_changed_since_read' || 'file_changed_since_prepare' => _('文件已被外部修改，请重新扫描', 'The file was changed by another program; rescan'),
        'file_changed_since_write' => _('文件已被修改，无法字节级还原', 'File changed since; cannot restore bytes'),
        'no_change' => _('无需改动', 'Nothing to change'),
        'unsupported_or_corrupt' => _('不支持的格式或文件已损坏', 'Unsupported or damaged file'),
        'cover_unsupported_by_format' => _('此格式不支持封面', 'This format cannot hold a cover'),
        'target_exists' => _('目标已存在', 'Target exists'),
        'cancelled' => _('已取消', 'Cancelled'),
        'nothing_to_undo' => nothingToUndo,
        _ when code.startsWith('verification_failed') => _('写入校验未通过，文件未改动（$code）', 'Verification failed, file untouched ($code)'),
        _ => code,
      };
}

class SDelegate extends LocalizationsDelegate<S> {
  final Locale? forced;
  const SDelegate(this.forced);
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<S> load(Locale locale) async => S((forced ?? locale).languageCode == 'zh');
  @override
  bool shouldReload(SDelegate old) => old.forced != forced;
}
