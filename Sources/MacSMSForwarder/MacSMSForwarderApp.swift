import AppKit
import ForwarderCore
import SwiftUI

/// App 入口：主窗口 + 菜单栏常驻
@main
struct MacSMSForwarderApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel.shared

  var body: some Scene {
    // 主窗口（单例窗口，关闭后可从菜单栏重新打开）
    Window("Mac短信转发", id: "main") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 860, minHeight: 560)
    }
    .defaultSize(width: 1000, height: 660)
    .windowResizability(.contentMinSize)

    // 菜单栏图标
    MenuBarExtra {
      MenuBarView()
        .environmentObject(model)
    } label: {
      Image(systemName: model.health == .error ? "message.badge" : "message")
    }
    .menuBarExtraStyle(.window)
  }
}

/// AppKit 代理：负责启动服务、控制「关闭窗口不退出」
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in AppModel.shared.start() }
  }

  /// 关闭主窗口后继续在菜单栏运行
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// 点击 Dock 图标时重新显示主窗口
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag {
      for window in sender.windows where window.canBecomeMain {
        window.makeKeyAndOrderFront(nil)
      }
    }
    return true
  }
}
