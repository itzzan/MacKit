@preconcurrency import ScreenCaptureKit
import AppKit

/// 某块屏幕在按下快捷键那一刻的画面（像素级）
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
}

/// 用苹果的 ScreenCaptureKit 把屏幕"冻住"
@MainActor
enum ScreenCapturer {
    static func capture(_ screens: [NSScreen] = NSScreen.screens) async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [FrozenScreen] = []
        for screen in screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                Log.capture.error("no SCDisplay for \(screen.localizedName, privacy: .public)")
                continue
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int((filter.contentRect.width * scale).rounded())
            config.height = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenScreen(screen: screen, image: image))
        }
        return result
    }
}
