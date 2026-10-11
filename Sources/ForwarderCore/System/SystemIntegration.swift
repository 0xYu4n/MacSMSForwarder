import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// 开机自启（登录项），基于 macOS 13+ 的 SMAppService
public enum LaunchAtLogin {
  public static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// 开启或关闭开机自启
  public static func set(_ enabled: Bool) throws {
    if enabled {
      if SMAppService.mainApp.status != .enabled {
        try SMAppService.mainApp.register()
      }
    } else {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      }
    }
  }
}

/// 防止系统空闲休眠（休眠后无法收发消息）；显示器仍可正常关闭
public final class SleepGuard: @unchecked Sendable {
  private var assertionID: IOPMAssertionID = 0
  private let lock = NSLock()

  public init() {}

  public var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return assertionID != 0
  }

  public func set(_ active: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if active, assertionID == 0 {
      var id: IOPMAssertionID = 0
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "Mac短信转发：保持收发消息" as CFString,
        &id)
      if result == kIOReturnSuccess { assertionID = id }
    } else if !active, assertionID != 0 {
      IOPMAssertionRelease(assertionID)
      assertionID = 0
    }
  }

  deinit {
    if assertionID != 0 { IOPMAssertionRelease(assertionID) }
  }
}
