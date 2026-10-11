import AppKit
import SwiftUI

/// 打赏页：展示微信赞赏码
struct DonateView: View {
  /// 赞赏码图片（打包时由 build-app.sh 复制到 Contents/Resources/donate.jpg）
  private let image: NSImage? = {
    guard let url = Bundle.main.url(forResource: "donate", withExtension: "jpg") else { return nil }
    return NSImage(contentsOf: url)
  }()

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        PageHeader(title: "打赏支持", subtitle: "Mac短信转发是免费开源软件，如果它帮到了你，欢迎请作者喝杯咖啡")

        VStack(spacing: 16) {
          if let image {
            Image(nsImage: image)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .frame(maxWidth: 340)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
          } else {
            // 开发调试（swift run）时没有打包资源
            EmptyStateView(symbol: "qrcode", title: "赞赏码未找到", message: "请使用 scripts/build-app.sh 打包后运行")
              .frame(height: 240)
          }

          Label("打开微信「扫一扫」即可赞赏", systemImage: "qrcode.viewfinder")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        Card {
          Label("其他支持方式", systemImage: "heart")
            .font(.headline)
          Text("在 GitHub 上点一颗 Star、提交 Issue 反馈问题，或者把它推荐给需要的朋友，都是对项目很大的鼓励。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(24)
    }
  }
}
