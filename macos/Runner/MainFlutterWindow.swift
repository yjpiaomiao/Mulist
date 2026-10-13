import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    Bookmarks.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Security-scoped bookmarks for library folders (the app is sandboxed).
/// A folder chosen in the open panel is accessible for the current session;
/// a bookmark created right away keeps the access across launches.
class Bookmarks: NSObject {
  static let channelName = "io.github.musicmanager/bookmarks"
  private var accessed: [String: URL] = [:]

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = Bookmarks()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in instance.handle(call, result: result) }
    objc_setAssociatedObject(channel, "mm_bookmarks", instance, .OBJC_ASSOCIATION_RETAIN)
    _channels.append(channel)
  }

  private static var _channels: [FlutterMethodChannel] = []

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "create":
      guard let path = args["path"] as? String else {
        return result(FlutterError(code: "bad_args", message: nil, details: nil))
      }
      do {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let data = try url.bookmarkData(
          options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        result(FlutterStandardTypedData(bytes: data))
      } catch {
        result(FlutterError(code: "bookmark_failed", message: error.localizedDescription, details: nil))
      }
    case "resolve":
      guard let typed = args["bookmark"] as? FlutterStandardTypedData else {
        return result(FlutterError(code: "bad_args", message: nil, details: nil))
      }
      var stale = false
      do {
        let url = try URL(
          resolvingBookmarkData: typed.data, options: [.withSecurityScope], relativeTo: nil,
          bookmarkDataIsStale: &stale)
        let ok = url.startAccessingSecurityScopedResource()
        if ok { accessed[url.path] = url }
        var refreshed: FlutterStandardTypedData? = nil
        if stale, let d = try? url.bookmarkData(
          options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        {
          refreshed = FlutterStandardTypedData(bytes: d)
        }
        result(["path": url.path, "stale": stale, "accessing": ok, "bookmark": refreshed as Any])
      } catch {
        result(FlutterError(code: "bookmark_unresolvable", message: error.localizedDescription, details: nil))
      }
    case "stopAccess":
      if let path = args["path"] as? String, let url = accessed.removeValue(forKey: path) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)
    case "reveal":
      if let path = args["path"] as? String {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
