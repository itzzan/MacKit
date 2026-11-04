// 坐标换算的单元测试：scripts/test.sh 会编译运行
import CoreGraphics
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1 }
}

// 主屏 1512×982 点（14 寸 MacBook Pro），图片 3024×1964 像素
let primaryH: CGFloat = 982
let mainScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
let viewSize = CGSize(width: 1512, height: 982)
let imageSize = CGSize(width: 3024, height: 1964)

check(Geometry.cocoaRect(fromCG: CGRect(x: 100, y: 50, width: 200, height: 100), primaryHeight: primaryH)
      == CGRect(x: 100, y: 832, width: 200, height: 100), "窗口框：CG 坐标 → Cocoa 坐标")

// 右边接一块 1920×1080 外接屏，底边对齐
let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
let onExternal = Geometry.viewRects(forCGWindowFrames: [CGRect(x: 1600, y: 100, width: 400, height: 300)],
                                    screenFrame: external, primaryHeight: primaryH)
check(onExternal == [CGRect(x: 88, y: 582, width: 400, height: 300)], "外接屏上的窗口换算到外接屏覆盖层")
check(Geometry.viewRects(forCGWindowFrames: [CGRect(x: 1600, y: 100, width: 400, height: 300)],
                         screenFrame: mainScreen, primaryHeight: primaryH).isEmpty, "外接屏上的窗口不出现在主屏")

let clipped = Geometry.viewRects(forCGWindowFrames: [CGRect(x: -100, y: 900, width: 300, height: 200)],
                                 screenFrame: mainScreen, primaryHeight: primaryH)
check(clipped == [CGRect(x: 0, y: 0, width: 200, height: 82)], "露出屏幕外的窗口只取屏幕内部分")

let front = CGRect(x: 100, y: 100, width: 200, height: 200)
let back = CGRect(x: 0, y: 0, width: 800, height: 600)
check(Geometry.topRect(containing: CGPoint(x: 150, y: 150), in: [front, back]) == front, "重叠时取最前面的窗口")
check(Geometry.topRect(containing: CGPoint(x: 500, y: 500), in: [front, back]) == back, "只在后面窗口上时取后面的")
check(Geometry.topRect(containing: CGPoint(x: 1000, y: 900), in: [front, back]) == nil, "桌面上没有窗口")

check(Geometry.rect(from: CGPoint(x: 200, y: 50), to: CGPoint(x: 100, y: 150))
      == CGRect(x: 100, y: 50, width: 100, height: 100), "往任意方向拖都得到正的框")

check(Geometry.pixelRect(forViewRect: CGRect(x: 0, y: 0, width: 100, height: 50), viewSize: viewSize, imageSize: imageSize)
      == CGRect(x: 0, y: 1864, width: 200, height: 100), "左下角的框 → 图片底部像素")
check(Geometry.pixelRect(forViewRect: CGRect(x: 0, y: 932, width: 100, height: 50), viewSize: viewSize, imageSize: imageSize)
      == CGRect(x: 0, y: 0, width: 200, height: 100), "左上角的框 → 图片顶部像素")
check(Geometry.pixelRect(forViewRect: CGRect(x: 10.25, y: 10.25, width: 100.5, height: 50.5), viewSize: viewSize, imageSize: imageSize)
      == CGRect(x: 21, y: 1843, width: 201, height: 101), "小数点的框四舍五入到整像素")
check(Geometry.pixelRect(forViewRect: CGRect(x: 1500, y: -10, width: 100, height: 100), viewSize: viewSize, imageSize: imageSize)
      == CGRect(x: 3000, y: 1784, width: 24, height: 180), "超出屏幕的部分被裁掉")

// 像素框 → 视图框（反向换算），贴图贴回原位置用
let px = CGRect(x: 21, y: 1843, width: 201, height: 101)
check(Geometry.viewRect(forPixelRect: px, viewSize: viewSize, imageSize: imageSize)
      == CGRect(x: 10.5, y: 10, width: 100.5, height: 50.5), "像素框换回视图框（对齐到半点）")
let roundTrip = CGRect(x: 100, y: 782, width: 100, height: 100)
check(Geometry.viewRect(forPixelRect: Geometry.pixelRect(forViewRect: roundTrip, viewSize: viewSize, imageSize: imageSize),
                        viewSize: viewSize, imageSize: imageSize) == roundTrip, "整点的框来回换算不变")

// 贴图：缩放、透明度、摆放
let pinFrame = CGRect(x: 100, y: 100, width: 200, height: 100)
check(PinGeometry.zoomedFrame(pinFrame, anchor: CGPoint(x: 200, y: 150), newSize: CGSize(width: 400, height: 200))
      == CGRect(x: 0, y: 50, width: 400, height: 200), "以中心为不动点放大 2 倍")
check(PinGeometry.zoomedFrame(pinFrame, anchor: CGPoint(x: 100, y: 100), newSize: CGSize(width: 400, height: 200))
      == CGRect(x: 100, y: 100, width: 400, height: 200), "以左下角为不动点放大，左下角不动")
check(PinGeometry.clampScale(50) == 10 && PinGeometry.clampScale(0.01) == 0.1, "缩放限制在 10% 到 1000%")
check(abs(PinGeometry.scrollZoomFactor(delta: 1, precise: false) - 1.1) < 1e-9, "鼠标滚轮往上一格放大 10%")
check(PinGeometry.scrollZoomFactor(delta: -1, precise: false) < 1, "鼠标滚轮往下缩小")
check(PinGeometry.scrollZoomFactor(delta: 20, precise: false) == pow(1.1, 3), "一次猛滚最多算 3 格")
check(abs(PinGeometry.opacity(after: 1, delta: -1, precise: false) - 0.95) < 1e-9, "⌥ + 滚轮往下一格，透明度降 5%")
check(PinGeometry.opacity(after: 0.12, delta: -5, precise: false) == 0.1, "透明度最低 10%，不会完全看不见")
check(PinGeometry.opacity(after: 0.98, delta: 2, precise: false) == 1, "透明度最高 100%")

let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
let small = PinGeometry.initialPlacement(size: CGSize(width: 200, height: 100), around: CGPoint(x: 700, y: 500), visible: visible)
check(small.scale == 1 && small.frame == CGRect(x: 600, y: 450, width: 200, height: 100), "小图以鼠标为中心、原大小贴出")
let corner = PinGeometry.initialPlacement(size: CGSize(width: 200, height: 100), around: CGPoint(x: 1500, y: 10), visible: visible)
check(corner.frame == CGRect(x: 1312, y: 0, width: 200, height: 100), "鼠标在屏幕角落时，贴图整个挪进屏幕")
let huge = PinGeometry.initialPlacement(size: CGSize(width: 3000, height: 1000), around: CGPoint(x: 700, y: 500), visible: visible)
check(abs(huge.frame.width - 1512 * 0.9) < 0.001 && visible.contains(huge.frame), "超大图缩到屏幕的 90% 以内")

// 台阶 3：调整选区、工具栏位置、箭头
let box = CGRect(x: 100, y: 100, width: 200, height: 100)
let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
check(EditGeometry.handleCenter(.topRight, of: box) == CGPoint(x: 300, y: 200), "右上角小方块在框的右上角")
check(EditGeometry.handle(at: CGPoint(x: 301, y: 199), in: box) == .topRight, "鼠标在右上角附近 → 认出右上角小方块")
check(EditGeometry.handle(at: CGPoint(x: 100, y: 150), in: box) == .left, "鼠标在左边中点 → 认出左边小方块")
check(EditGeometry.handle(at: CGPoint(x: 200, y: 150), in: box) == nil, "框中间不算小方块")
check(EditGeometry.resize(box, handle: .bottomRight, to: CGPoint(x: 350, y: 50), bounds: screen)
      == CGRect(x: 100, y: 50, width: 250, height: 150), "拖右下角改大小，左上角不动")
check(EditGeometry.resize(box, handle: .left, to: CGPoint(x: 400, y: 150), bounds: screen)
      == CGRect(x: 300, y: 100, width: 100, height: 100), "左边拖过右边 → 框翻过来")
check(EditGeometry.resize(box, handle: .right, to: CGPoint(x: 2000, y: 150), bounds: screen).maxX == 1512, "拖出屏幕外 → 停在屏幕边上")
check(EditGeometry.resize(box, handle: .right, to: CGPoint(x: 101, y: 150), bounds: screen).width == 4, "框最小 4 个点宽")
check(EditGeometry.resize(box, handle: .top, to: CGPoint(x: 999, y: 300), bounds: screen)
      == CGRect(x: 100, y: 100, width: 200, height: 200), "拖上边只改高度，不改宽度")
check(EditGeometry.move(box, by: CGVector(dx: -500, dy: 0), within: screen) == CGRect(x: 0, y: 100, width: 200, height: 100), "挪框不出屏幕")
check(EditGeometry.move(box, by: CGVector(dx: 1, dy: 0), within: screen).minX == 101, "方向键挪 1 个点")

let bar = CGSize(width: 300, height: 40)
check(EditGeometry.toolbarOrigin(size: bar, selection: CGRect(x: 500, y: 300, width: 400, height: 300), bounds: screen)
      == CGPoint(x: 600, y: 252), "工具栏在框下方、右对齐")
check(EditGeometry.toolbarOrigin(size: bar, selection: CGRect(x: 500, y: 20, width: 400, height: 300), bounds: screen)
      == CGPoint(x: 600, y: 328), "框贴着屏幕底部 → 工具栏放上方")
check(EditGeometry.toolbarOrigin(size: bar, selection: screen, bounds: screen)
      == CGPoint(x: 1208, y: 8), "整屏截图 → 工具栏放在框里右下角")
check(EditGeometry.toolbarOrigin(size: bar, selection: CGRect(x: 0, y: 300, width: 100, height: 100), bounds: screen).x == 4,
      "框很窄靠左 → 工具栏不出屏幕左边")

let head = EditGeometry.arrow(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4)
check(head.tip == CGPoint(x: 100, y: 0) && head.left == CGPoint(x: 84, y: 8) && head.right == CGPoint(x: 84, y: -8),
      "箭头头部：尖在终点，两翼对称")
check(abs(head.shaftEnd.x - 87.2) < 0.001, "箭杆画到箭头里面一点，接缝不露白")

// 台阶 4：剪贴板历史里的文字处理
check(ClipboardText.title(from: "  你好\n\n  MacKit\t世界  ") == "你好 MacKit 世界", "列表标题：换行和多余空白压成一个空格")
check(ClipboardText.title(from: String(repeating: "字", count: 300)).count == 201, "列表标题最多 200 字，后面加省略号")
check(ClipboardText.matches("mac", in: "你好 MacKit"), "搜索不分大小写")
check(ClipboardText.matches("世界", in: "你好世界"), "搜索中文")
check(ClipboardText.matches("abc", in: "ＡＢＣ全角"), "搜索不分全角半角")
check(ClipboardText.matches("  ", in: "随便"), "空搜索 = 全部显示")
check(!ClipboardText.matches("没有", in: "你好世界"), "搜不到的不显示")
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15))!
check(ClipboardText.relativeTime(now.addingTimeInterval(-30), now: now, calendar: cal) == "刚刚", "30 秒前 → 刚刚")
check(ClipboardText.relativeTime(now.addingTimeInterval(-300), now: now, calendar: cal) == "5 分钟前", "5 分钟前")
check(ClipboardText.relativeTime(now.addingTimeInterval(-3 * 3600), now: now, calendar: cal) == "3 小时前", "同一天 → 几小时前")
check(ClipboardText.relativeTime(now.addingTimeInterval(-20 * 3600), now: now, calendar: cal) == "昨天", "昨天")
check(ClipboardText.relativeTime(cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9))!, now: now, calendar: cal) == "10-28",
      "更早 → 月-日")

// 台阶 5：录屏的坐标和尺寸
check(RecordGeometry.sourceRect(forViewRect: CGRect(x: 100, y: 100, width: 200, height: 100), screenHeight: 982)
      == CGRect(x: 100, y: 782, width: 200, height: 100), "框选区域 → 录制区域（左上原点）")
check(RecordGeometry.alignedSourceRect(CGRect(x: 10.3, y: 20.6, width: 100.7, height: 50.3), scale: 2,
                                       screenSize: CGSize(width: 1512, height: 982))
      == CGRect(x: 10.5, y: 20.5, width: 100, height: 50), "录制区域对齐到整像素，像素宽高是偶数")
check(RecordGeometry.alignedSourceRect(CGRect(x: 1500, y: 970, width: 100, height: 100), scale: 2,
                                       screenSize: CGSize(width: 1512, height: 982))
      == CGRect(x: 1412, y: 882, width: 100, height: 100), "录制区域超出屏幕 → 挪回屏幕里")
check(RecordGeometry.outputSize(pixelWidth: 3025, pixelHeight: 1965, quality: .original60) == (3024, 1964),
      "原始清晰度：像素宽高取偶数")
check(RecordGeometry.outputSize(pixelWidth: 3024, pixelHeight: 1964, quality: .hd30) == (1662, 1080),
      "1080p 档：Retina 全屏缩到 1080 高（不会算成 1078）")
check(RecordGeometry.outputSize(pixelWidth: 1000, pixelHeight: 2000, quality: .hd30) == (960, 1920), "1080p 档：竖着的画面缩到 1920 高")
check(RecordGeometry.outputSize(pixelWidth: 800, pixelHeight: 600, quality: .hd30) == (800, 600), "1080p 档：小区域不放大")
check(RecordQuality.original60.fps == 60 && RecordQuality.hd30.fps == 30, "两档画质的帧率")
check(RecordGeometry.durationText(0) == "00:00" && RecordGeometry.durationText(42) == "00:42"
      && RecordGeometry.durationText(723) == "12:03" && RecordGeometry.durationText(3723) == "1:02:03", "菜单栏时长显示")
let recDate = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15, minute: 20, second: 33))!
check(RecordGeometry.fileName(for: recDate) == "MacKit_录屏_2026-11-04_15-20-33.mp4", "录屏文件名")

// 录制小条放哪（2026-11-04 验收后加：只有菜单栏红点，常常不知道在不在录）
let vis = CGRect(x: 0, y: 0, width: 1728, height: 1084)
let hud = CGSize(width: 220, height: 36)
check(RecordGeometry.hudOrigin(size: hud, target: CGRect(x: 0, y: 0, width: 1728, height: 1117), visible: vis, fullScreen: true)
      == CGPoint(x: 754, y: 1036), "录整屏：小条在屏幕顶部正中")
check(RecordGeometry.hudOrigin(size: hud, target: CGRect(x: 400, y: 300, width: 600, height: 400), visible: vis, fullScreen: false)
      == CGPoint(x: 780, y: 712), "录一块区域：小条在区域右上角外面")
check(RecordGeometry.hudOrigin(size: hud, target: CGRect(x: 400, y: 600, width: 600, height: 470), visible: vis, fullScreen: false)
      == CGPoint(x: 780, y: 552), "区域贴着屏幕顶 → 小条放下面")
check(RecordGeometry.hudOrigin(size: hud, target: CGRect(x: 0, y: 0, width: 1728, height: 1084), visible: vis, fullScreen: false)
      == CGPoint(x: 1504, y: 1036), "区域占满屏幕 → 小条放在区域里的右上角")
check(RecordGeometry.hudOrigin(size: hud, target: CGRect(x: 10, y: 300, width: 100, height: 100), visible: vis, fullScreen: false).x == 4,
      "区域很窄靠左 → 小条不出屏幕")

// 台阶 6：定时录制
let sh = Calendar.current
let three = sh.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15, minute: 0))!
let tonight = RecordSchedule.nextStart(hour: 20, minute: 0, now: three)
check(sh.component(.day, from: tonight) == 4 && sh.component(.hour, from: tonight) == 20, "指定 20:00 开始：今天还没到 → 今天 20:00")
let morning = RecordSchedule.nextStart(hour: 8, minute: 30, now: three)
check(sh.component(.day, from: morning) == 5 && sh.component(.minute, from: morning) == 30, "指定 08:30 开始：今天已经过了 → 明天 08:30")
check(RecordSchedule.startTitle(nil, now: three) == "立即开始" && RecordSchedule.startTitle(tonight, now: three) == "20:00 开始"
      && RecordSchedule.startTitle(morning, now: three) == "明天 08:30 开始", "控制条上的开始时间文字")
check(!RecordSchedule.shouldAutoStop(recorded: 59, limitMinutes: 1) && RecordSchedule.shouldAutoStop(recorded: 60, limitMinutes: 1)
      && !RecordSchedule.shouldAutoStop(recorded: 99_999, limitMinutes: 0), "录多久自动停：到点才停，不限时永远不停")
check(RecordSchedule.autoStopTitle(0) == "不限时" && RecordSchedule.autoStopTitle(5) == "5 分钟后停", "控制条上的自动停文字")

// 录制框能调：鼠标在不在虚线上、改完不出屏幕
let rr = CGRect(x: 100, y: 100, width: 400, height: 300)
check(RecordGeometry.isNearEdge(CGPoint(x: 100, y: 250), of: rr) && RecordGeometry.isNearEdge(CGPoint(x: 96, y: 250), of: rr)
      && RecordGeometry.isNearEdge(CGPoint(x: 300, y: 404), of: rr), "鼠标在虚线内外 6 点以内 → 算在虚线上")
check(!RecordGeometry.isNearEdge(CGPoint(x: 300, y: 250), of: rr) && !RecordGeometry.isNearEdge(CGPoint(x: 80, y: 250), of: rr),
      "框里面、离框远的地方不算")
check(RecordGeometry.clampRegion(CGRect(x: -50, y: 10, width: 10, height: 10), within: CGRect(x: 0, y: 0, width: 1728, height: 1117))
      == CGRect(x: 0, y: 10, width: 40, height: 30), "录制框最小 40×30 点、不出屏幕")

// 台阶 6 第二批：按键显示成什么、牌子和摄像头放哪
check(KeyFormatter.text(keyCode: 21, modifiers: [.shift, .command], characters: "$") == "⇧ ⌘ 4", "⇧⌘4 显示成「⇧ ⌘ 4」（不是 $）")
check(KeyFormatter.text(keyCode: 8, modifiers: [.command], characters: "c") == "⌘ C", "⌘C")
check(KeyFormatter.text(keyCode: 40, modifiers: [.control, .option, .shift, .command], characters: "k") == "⌃ ⌥ ⇧ ⌘ K",
      "修饰键按苹果的顺序：⌃ ⌥ ⇧ ⌘")
check(KeyFormatter.text(keyCode: 0, modifiers: [], characters: "a") == nil
      && KeyFormatter.text(keyCode: 0, modifiers: [.shift], characters: "A") == nil
      && KeyFormatter.text(keyCode: 49, modifiers: [], characters: " ") == nil, "普通打字（包括 ⇧ 大写、空格）不显示")
check(KeyFormatter.text(keyCode: 0, modifiers: [], characters: "a", shortcutsOnly: false) == "A", "选「全部按键」时打字也显示")
check(KeyFormatter.text(keyCode: 36, modifiers: [], characters: "\r") == "↩" && KeyFormatter.text(keyCode: 53, modifiers: [], characters: nil) == "⎋"
      && KeyFormatter.text(keyCode: 123, modifiers: [], characters: nil) == "←" && KeyFormatter.text(keyCode: 96, modifiers: [], characters: nil) == "F5",
      "功能键不带修饰键也显示：↩ ⎋ ← F5")
check(KeyFormatter.text(keyCode: 49, modifiers: [.command], characters: " ") == "⌘ 空格", "⌘ 空格")
let target6 = CGRect(x: 400, y: 300, width: 600, height: 400), vis6 = CGRect(x: 0, y: 0, width: 1728, height: 1084)
check(RecordGeometry.keyCastOrigin(size: CGSize(width: 200, height: 44), target: target6, visible: vis6, fullScreen: false)
      == CGPoint(x: 600, y: 324), "按键牌子在录制区域下方正中")
check(RecordGeometry.keyCastOrigin(size: CGSize(width: 200, height: 44), target: target6, visible: vis6, fullScreen: true)
      == CGPoint(x: 764, y: 60), "录整屏：按键牌子在屏幕下方正中")
check(RecordGeometry.cameraFrame(side: 180, target: target6, visible: vis6) == CGRect(x: 804, y: 316, width: 180, height: 180),
      "摄像头画面一开始在录制区域右下角")
check(RecordGeometry.cameraFrame(side: 180, target: vis6, visible: vis6).maxX <= vis6.maxX - 4, "摄像头画面不出屏幕")
check(RecordGeometry.clampCameraSide(50) == 80 && RecordGeometry.clampCameraSide(500) == 400, "摄像头画面 80 到 400 点")

// 台阶 7：去掉换行、颜色、找边、放大镜位置、测量文字
check(OCRText.joinLines(["你好", "世界"]) == "你好世界", "去掉换行：中文接中文不加空格")
check(OCRText.joinLines(["Hello", "world"]) == "Hello world", "去掉换行：英文单词之间加空格")
check(OCRText.joinLines(["使用", "MacKit", "很好用"]) == "使用MacKit很好用", "去掉换行：中英文之间不加空格")
check(OCRText.joinLines(["end.", "Next"]) == "end. Next", "去掉换行：英文句号后接英文加空格")
check(OCRText.joinLines(["well-", "known"]) == "well-known" && OCRText.joinLines(["2026-", "11-04"]) == "2026-11-04",
      "去掉换行：行尾是 - 直接接上，连字符保留")
check(OCRText.joinLines(["  a  ", "", "b"]) == "a b", "去掉换行：空行和多余空格去掉")
check(OCRText.url(in: " https://example.com/a ")?.host == "example.com" && OCRText.url(in: "hello") == nil
      && OCRText.url(in: "ftp://x.com") == nil, "二维码内容是不是网址")
check(OCRText.normalizePunctuation("let tool = ScreenshotTool（）") == "let tool = ScreenshotTool()"
      && OCRText.normalizePunctuation("a：b，c　d") == "a:b,c d", "没有中文的行：全角标点改回半角")
check(OCRText.normalizePunctuation("今天天气不错，去公园吧。（括号）") == "今天天气不错，去公园吧。（括号）", "有中文的行：全角标点不动")
check(ColorText.hex(255, 59, 48) == "#FF3B30" && ColorText.rgb(255, 59, 48) == "255, 59, 48", "颜色写成 HEX / RGB")

// 找边：20×10 的白图，中间一块黑（x 5…14，y 2…7）
let edgePixel = { (x: Int, y: Int) -> (Int, Int, Int) in (5...14).contains(x) && (2...7).contains(y) ? (0, 0, 0) : (255, 255, 255) }
let inside = EdgeFinder.distances(fromX: 8, y: 4, width: 20, height: 10, pixel: edgePixel)
check(inside.left + inside.right + 1 == 10 && inside.up + inside.down + 1 == 6, "鼠标在黑块里 → 量出黑块宽 10、高 6")
let beside = EdgeFinder.distances(fromX: 2, y: 4, width: 20, height: 10, pixel: edgePixel)
check(beside.left + beside.right + 1 == 5 && beside.up + beside.down + 1 == 10, "鼠标在黑块左边 → 量到黑块的边为止")
let nearly = EdgeFinder.distances(fromX: 1, y: 0, width: 4, height: 1, pixel: { x, _ in x == 2 ? (245, 245, 245) : (255, 255, 255) })
check(nearly.left + nearly.right + 1 == 4, "颜色只差一点点（抗锯齿、阴影）不算边")

let bigBounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
check(MagnifierGeometry.origin(size: CGSize(width: 120, height: 150), cursor: CGPoint(x: 100, y: 500), bounds: bigBounds)
      == CGPoint(x: 120, y: 330), "放大镜在鼠标右下方")
check(MagnifierGeometry.origin(size: CGSize(width: 120, height: 150), cursor: CGPoint(x: 1700, y: 500), bounds: bigBounds).x == 1560,
      "靠右边 → 放大镜翻到左边")
check(MagnifierGeometry.origin(size: CGSize(width: 120, height: 150), cursor: CGPoint(x: 100, y: 50), bounds: bigBounds).y == 70,
      "靠下边 → 放大镜翻到上边")
check(MeasureText.points(240, scale: 2) == "120" && MeasureText.points(241, scale: 2) == "120.5"
      && MeasureText.size(widthPixels: 240, heightPixels: 96, scale: 2) == ("120 × 48", "240 × 96"), "测量结果：点和屏幕像素")

// MARK: 长截图拼接
// 造一张 64 像素宽的假网页：顶部固定导航栏 20 行、底部固定输入框 16 行，中间 900 行内容（7 行字 + 5 行空白，一直重复）
let pageW = 64, headerH = 20, footerH = 16, visibleH = 160, contentH = 900
let frameH = headerH + visibleH + footerH
func contentPixel(_ x: Int, _ y: Int) -> UInt8 {
    guard y < contentH else { return 255 }                               // 网页到头了，再往下是空白
    let line = y / 12, row = y % 12
    guard row < 7, x >= 4, x < pageW - 4 else { return 255 }
    var h = UInt32(truncatingIfNeeded: line &* 7919 &+ (x / 3) &* 104729 &+ row &* 31)
    h = (h ^ (h >> 13)) &* 1274126177
    return (h >> 7) % 3 == 0 ? 40 : 250
}
func headerPixel(_ x: Int, _ y: Int) -> UInt8 { y == headerH - 1 ? 150 : (x % 8 < 4 ? 210 : 120) }
func footerPixel(_ x: Int, _ y: Int) -> UInt8 { y == 0 ? 170 : (x > 10 && x < 40 && y > 4 && y < 12 ? 230 : 200) }
func pageRows(_ rows: [(Int) -> UInt8]) -> [UInt8] {
    var px: [UInt8] = []
    for row in rows { for x in 0..<pageW { let v = row(x); px += [v, v, v, 255] } }
    return px
}
/// 滚到 offset 时拍到的画面；noise：每个像素随机加减一点（模拟文字抗锯齿的细微差别）
func pageFrame(offset: Int, noise: Bool = false, poke: Bool = false) -> StitchFrame {
    var rows: [(Int) -> UInt8] = []
    for y in 0..<headerH { rows.append { headerPixel($0, y) } }
    for y in 0..<visibleH { rows.append { contentPixel($0, offset + y) } }
    for y in 0..<footerH { rows.append { footerPixel($0, y) } }
    var px = pageRows(rows)
    if noise {
        var seed: UInt32 = UInt32(offset) &* 2654435761 &+ 1
        // 只有会滚的内容有细微差别；固定的导航栏、输入框每次画得一模一样
        for i in stride(from: headerH * pageW * 4, to: (headerH + visibleH) * pageW * 4, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            let delta = Int(seed >> 29) - 3                                  // -3…4
            let v = UInt8(clamping: Int(px[i]) + delta)
            px[i] = v; px[i + 1] = v; px[i + 2] = v
        }
    }
    if poke { for x in 30..<33 { for y in 100..<102 { let i = (y * pageW + x) * 4; px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 } } }
    return StitchFrame(width: pageW, height: frameH, pixels: px)
}
func expectedPage(lastOffset: Int) -> [UInt8] {
    var rows: [(Int) -> UInt8] = []
    for y in 0..<headerH { rows.append { headerPixel($0, y) } }
    for y in 0..<(lastOffset + visibleH) { rows.append { contentPixel($0, y) } }
    for y in 0..<footerH { rows.append { footerPixel($0, y) } }
    return pageRows(rows)
}

let stitcher = ScrollStitcher(thumbWidth: 32)
check(stitcher.add(pageFrame(offset: 0)) == .first, "长截图：第一张")
check(stitcher.add(pageFrame(offset: 0)) == .same, "长截图：画面没变 → 不拼")
check(stitcher.add(pageFrame(offset: 0, poke: true)) == .same, "长截图：只有一小块在变（光标闪）→ 不拼，也不当成固定头尾")
check(stitcher.add(pageFrame(offset: 13)) == .appended(13), "长截图：往下滚 13 行 → 接上 13 行")
check(stitcher.bands?.top == headerH && stitcher.bands?.bottom == footerH, "长截图：认出顶部导航栏 20 行、底部输入框 16 行")
check(stitcher.add(pageFrame(offset: 37)) == .appended(24), "长截图：再滚 24 行")
check(stitcher.add(pageFrame(offset: 60)) == .appended(23), "长截图：再滚 23 行")
check(stitcher.add(pageFrame(offset: 45)) == .up(15), "长截图：往回滚 15 行 → 长图末尾也退回 15 行")
check(stitcher.add(pageFrame(offset: 90)) == .appended(45), "长截图：滚回来接着拼")
check(stitcher.add(pageFrame(offset: 300)) == .lost, "长截图：一下跳太远 → 对不上")
check(stitcher.add(pageFrame(offset: 120)) == .appended(30), "长截图：往回滚到能对上的地方 → 接着拼")
check(stitcher.add(pageFrame(offset: 121)) == .appended(1), "长截图：只滚 1 行也认得出")
var lastOffset = 121
for offset in stride(from: 200, through: contentH - visibleH, by: 60) {
    _ = stitcher.add(pageFrame(offset: offset))
    lastOffset = offset
}
check(stitcher.add(pageFrame(offset: lastOffset + 40)) == .appended(40), "长截图：滚到底页面弹一下，露出 40 行空白")
check(stitcher.add(pageFrame(offset: lastOffset)) == .up(40), "长截图：弹回来 → 空白退掉")
let stitched = stitcher.result()
check(stitched?.height == headerH + lastOffset + visibleH + footerH && stitched?.pixels == expectedPage(lastOffset: lastOffset),
      "长截图：拼出来和原网页一模一样（导航栏、输入框各一份，高 \(stitched?.height ?? 0)）")
check(stitcher.thumbnail()?.width == 32 && stitcher.thumbnail()?.height == stitcher.canvasRows / 2, "长截图：预览小图按宽度等比缩小")
check(abs(stitcher.screens - Double(stitcher.totalHeight) / Double(frameH)) < 0.001 && stitcher.totalHeight == stitched?.height,
      "长截图：总高度和屏数")

let noisy = ScrollStitcher()
var noisyLast = 0
_ = noisy.add(pageFrame(offset: 0, noise: true))
for offset in [17, 40, 71, 100, 133, 160, 199] {
    if case .appended = noisy.add(pageFrame(offset: offset, noise: true)) { noisyLast = offset }
}
check(noisyLast == 199 && noisy.result()?.height == headerH + 199 + visibleH + footerH, "长截图：画面有细微差别（抗锯齿）也对得上")

let capped = ScrollStitcher(maxHeight: 400)
_ = capped.add(pageFrame(offset: 0))
var cappedEvents: [ScrollStitcher.Event] = []
for offset in stride(from: 50, through: 400, by: 50) { cappedEvents.append(capped.add(pageFrame(offset: offset))) }
check(cappedEvents.contains(.full) && capped.result()?.height == 400 && capped.isFull, "长截图：到高度上限就停，正好 400 行")

let above = ScrollStitcher()
_ = above.add(pageFrame(offset: 100))
let aboveEvents = [above.add(pageFrame(offset: 130)), above.add(pageFrame(offset: 60)), above.add(pageFrame(offset: 140))]
check(aboveEvents == [.appended(30), .up(0), .appended(10)], "长截图：滚到比开始的地方还上面 → 先不管，滚回来接着拼")

let still = ScrollStitcher()
_ = still.add(pageFrame(offset: 0))
check(still.result()?.pixels == pageFrame(offset: 0).pixels, "长截图：一下没滚就完成 → 就是第一张")
let blank = StitchFrame(width: 20, height: 60, pixels: [UInt8](repeating: 255, count: 20 * 60 * 4))
let blankStitcher = ScrollStitcher()
_ = blankStitcher.add(blank)
check(blankStitcher.add(blank) == .same, "长截图：一片空白 → 不拼")

let region = ScreenRegion(displayID: 1, screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                          viewRect: CGRect(x: 100.25, y: 200, width: 600, height: 700))
check(region.sourceRect(scale: 2) == CGRect(x: 100.5, y: 217, width: 600, height: 700), "长截图：源区域换成左上原点、对齐到整像素")
check(ScreenRegion(displayID: 2, screenFrame: CGRect(x: 1728, y: 0, width: 1920, height: 1080),
                   viewRect: CGRect(x: 10, y: 20, width: 30, height: 40)).globalRect == CGRect(x: 1738, y: 20, width: 30, height: 40),
      "长截图：外接屏上的框换成全局坐标")
let lsVisible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
check(LongShotGeometry.previewFrame(region: CGRect(x: 200, y: 200, width: 600, height: 700), visible: lsVisible, width: 110)
      == CGRect(x: 816, y: 200, width: 110, height: 700), "长截图：预览条在框的右边、顶端对齐")
check(LongShotGeometry.previewFrame(region: CGRect(x: 1000, y: 200, width: 700, height: 700), visible: lsVisible, width: 110).maxX
      == 984, "长截图：右边放不下 → 放左边")
check(LongShotGeometry.previewFrame(region: CGRect(x: 0, y: 0, width: 1728, height: 1080), visible: lsVisible, width: 110)
      == CGRect(x: 1610, y: 4, width: 110, height: 1072), "长截图：框占满整屏 → 预览条贴着右边放在框里")
check(LongShotGeometry.thumbLayout(thumbSize: CGSize(width: 160, height: 100), box: CGSize(width: 80, height: 300))
      == CGRect(x: 0, y: 250, width: 80, height: 50), "长截图：小图比预览条短 → 靠上")
check(LongShotGeometry.thumbLayout(thumbSize: CGSize(width: 160, height: 1000), box: CGSize(width: 80, height: 300))
      == CGRect(x: 0, y: 0, width: 80, height: 500), "长截图：小图比预览条长 → 露出最下面")
check(LongShotGeometry.progressText(totalHeight: 6200, screens: 3.18) == "已拼约 3.2 屏　6200 像素高"
      && LongShotGeometry.progressText(totalHeight: 30000, screens: 13.4) == "已拼约 13 屏　30000 像素高", "长截图：进度文字")

print(failures == 0 ? "UNIT TESTS OK" : "UNIT TESTS FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
