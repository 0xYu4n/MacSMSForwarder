import AppKit
import ApplicationServices
import Foundation
import IMsgCore

/// 权限状态
public enum PermissionState: String, Sendable, Codable {
  case granted
  case denied
  /// 尚未询问过用户（仅自动化权限会出现）
  case notDetermined
  case unknown
}

/// 系统权限检测与引导
public enum Permissions {
  /// 「信息」App 的 Bundle ID
  public static let messagesBundleID = "com.apple.MobileSMS"

  /// 完全磁盘访问：能否读取 chat.db
  public static func fullDiskAccess(chatDBPath: String = MessageStore.defaultPath) -> PermissionState {
    let fd = Darwin.open(chatDBPath, O_RDONLY)
    if fd >= 0 {
      Darwin.close(fd)
      return .granted
    }
    // 文件不存在（从未使用过「信息」App）时无法判断
    return errno == ENOENT ? .unknown : .denied
  }

  /// 自动化权限：能否向「信息」App 发送 Apple Events
  /// - Parameter ask: 为 true 时若尚未询问会弹出系统授权框（需要「信息」正在运行）
  public static func automation(ask: Bool = false) -> PermissionState {
    let target = NSAppleEventDescriptor(bundleIdentifier: messagesBundleID)
    guard let desc = target.aeDesc else { return .unknown }
    let status = AEDeterminePermissionToAutomateTarget(
      desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    switch status {
    case noErr: return .granted
    case OSStatus(errAEEventNotPermitted): return .denied
    case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
    // procNotFound：「信息」未运行，无法判断
    default: return .unknown
    }
  }

  /// 「信息」App 是否正在运行
  public static var isMessagesRunning: Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty
  }

  /// 在后台启动「信息」App（不激活窗口）
  public static func launchMessagesInBackground() {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID)
    else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.hides = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
  }

  /// 打开系统设置中的「完全磁盘访问」页面
  public static func openFullDiskAccessSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
  }

  /// 打开系统设置中的「自动化」页面
  public static func openAutomationSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
  }

  private static func open(_ string: String) {
    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
  }
}
