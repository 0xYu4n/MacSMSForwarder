import Foundation
import Testing

@testable import ForwarderCore

/// 版本比较与 GitHub 返回解析测试
struct UpdateCheckerTests {
  @Test func compareVersions() {
    #expect(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
    #expect(UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
    #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
    #expect(!UpdateChecker.isNewer("v0.1.0", than: "0.1.0"))
    #expect(!UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
    // 开发版（带后缀）低于同号正式版
    #expect(UpdateChecker.isNewer("0.1.0", than: "0.1.0-dev.abc1234"))
    #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.1-dev.abc1234"))
  }

  @Test func parseRelease() throws {
    let json = """
      {"tag_name":"v0.2.0","html_url":"https://github.com/0xYu4n/MacSMSForwarder/releases/tag/v0.2.0",
       "body":"新功能","published_at":"2026-10-11T05:50:00Z"}
      """
    let release = try #require(UpdateChecker.parse(Data(json.utf8)))
    #expect(release.version == "0.2.0")
    #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    #expect(release.notes == "新功能")
    #expect(release.publishedAt != nil)
    #expect(UpdateChecker.parse(Data("{}".utf8)) == nil)
  }
}
