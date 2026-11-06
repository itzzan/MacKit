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

// MARK: 横向长截图（台阶 25）
let tf = pageFrame(offset: 37)
let tft = tf.transposed()
check(tft.width == tf.height && tft.height == tf.width && tft.transposed().pixels == tf.pixels
      && tft.pixels[(5 * tf.height + 9) * 4] == tf.pixels[(9 * tf.width + 5) * 4], "转 90 度：宽高对调，第 x 列变成第 x 行，再转一次就转回来")
let shiftCost = ScrollMatcher.moveWithCost(from: RowPrints(pageFrame(offset: 0)), to: RowPrints(pageFrame(offset: 13)), top: headerH, bottom: footerH)
check(shiftCost.move == .down(13) && shiftCost.cost < 0.01, "比对时交出对得多准：一模一样的就是 0")
let sideways = DirectionalStitcher(thumbWidth: 32)
var wideEvents: [ScrollStitcher.Event] = []
for offset in [0, 0, 13, 37, 60, 45, 90, 150, 210] { wideEvents.append(sideways.add(pageFrame(offset: offset).transposed())) }
let wideExpected = StitchFrame(width: pageW, height: headerH + 210 + visibleH + footerH, pixels: expectedPage(lastOffset: 210)).transposed()
check(sideways.axis == .horizontal && wideEvents == [.first, .same, .appended(13), .appended(24), .appended(23), .up(15), .appended(45), .appended(60), .appended(60)],
      "横着滚：认成横着拼，一段段接上，往回滚就退回去")
check(sideways.result()?.width == wideExpected.width && sideways.result()?.height == wideExpected.height && sideways.result()?.pixels == wideExpected.pixels,
      "横着拼出来和原表格一模一样（左边固定的一列、右边固定的一列各一份）")
check(sideways.thumbnail()?.height == 32 && sideways.length == wideExpected.width, "横着拼：预览小图转回来是横着的；长度是宽")
let downward = DirectionalStitcher()
for offset in [0, 13, 37] { _ = downward.add(pageFrame(offset: offset)) }
check(downward.axis == .vertical && downward.result()?.height == headerH + 37 + visibleH + footerH, "往下滚：还是竖着拼")
func gridFrame(ox: Int, oy: Int, w: Int = 120, h: Int = 90) -> StitchFrame {
    var px: [UInt8] = []
    px.reserveCapacity(w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            var v = UInt32(truncatingIfNeeded: ((ox + x) / 3) &* 104729 &+ ((oy + y) / 5) &* 7919)
            v = (v ^ (v >> 13)) &* 1274126177
            let g: UInt8 = (v >> 7) % 3 == 0 ? 40 : 245
            px += [g, g, g, 255]
        }
    }
    return StitchFrame(width: w, height: h, pixels: px)
}
let gridH = DirectionalStitcher()
let gridEvents = [gridH.add(gridFrame(ox: 0, oy: 0)), gridH.add(gridFrame(ox: 20, oy: 0))]
let crossH = gridH.add(gridFrame(ox: 20, oy: 15))
let crossHFlag = gridH.crossScroll
check(gridEvents == [.first, .appended(20)] && gridH.axis == .horizontal && crossH == .lost && crossHFlag
      && gridH.add(gridFrame(ox: 40, oy: 0)) == .appended(20) && !gridH.crossScroll,
      "先横着接上了：再上下滚不拼，认得出是往另一个方向滚了；滚回来接着拼")
let gridV = DirectionalStitcher()
_ = gridV.add(gridFrame(ox: 0, oy: 0))
_ = gridV.add(gridFrame(ox: 0, oy: 20))
let crossV = gridV.add(gridFrame(ox: 15, oy: 20))
check(gridV.axis == .vertical && crossV == .lost && gridV.crossScroll, "先竖着接上了：再左右滚不拼，认得出是往另一个方向滚了")
let hVisible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
check(LongShotGeometry.horizontalPreviewFrame(region: CGRect(x: 200, y: 200, width: 900, height: 400), visible: hVisible, height: 90,
                                              avoid: CGRect(x: 500, y: 140, width: 600, height: 40))
      == CGRect(x: 200, y: 616, width: 900, height: 90), "横着拼：预览条在框上面，和框一样宽")
check(LongShotGeometry.horizontalPreviewFrame(region: CGRect(x: 200, y: 600, width: 900, height: 460), visible: hVisible, height: 90,
                                              avoid: CGRect(x: 500, y: 540, width: 600, height: 40))
      == CGRect(x: 200, y: 434, width: 900, height: 90), "框顶到屏幕上边：预览条放到框和控制条下面")
check(LongShotGeometry.horizontalPreviewFrame(region: hVisible, visible: hVisible, height: 90, avoid: CGRect(x: 1100, y: 20, width: 600, height: 40))
      == CGRect(x: 4, y: 982, width: 1720, height: 90), "框占满整屏：预览条贴着框的上边放在框里")
check(LongShotGeometry.horizontalThumbLayout(thumbSize: CGSize(width: 100, height: 160), box: CGSize(width: 300, height: 80))
      == CGRect(x: 0, y: 0, width: 50, height: 80)
      && LongShotGeometry.horizontalThumbLayout(thumbSize: CGSize(width: 1000, height: 160), box: CGSize(width: 300, height: 80))
      == CGRect(x: -200, y: 0, width: 500, height: 80), "横着拼：小图等高缩放，窄就靠左，宽就露出最右边")
check(LongShotGeometry.progressText(totalHeight: 6200, screens: 3.18, axis: .horizontal) == "已拼约 3.2 屏　6200 像素宽", "横着拼的进度写像素宽")

// MARK: 系统状态、防休眠的文字
check(SystemText.size(312_000_000_000, decimal: true) == "312 GB" && SystemText.size(1_200_000, decimal: true) == "1.2 MB"
      && SystemText.size(80_400, decimal: true) == "80 KB" && SystemText.size(999, decimal: true) == "999 B",
      "磁盘、网速按 1000 换算（和访达一致）")
check(SystemText.size(18.2 * 1_073_741_824, decimal: false) == "18.2 GB" && SystemText.size(24 * 1_073_741_824, decimal: false) == "24 GB"
      && SystemText.size(2 * 1_099_511_627_776, decimal: false) == "2 TB", "内存按 1024 换算（和活动监视器一致），整数不带 .0")
check(SystemText.rate(1_234_000) == "1.2 MB/s" && SystemText.rate(80_000) == "80 KB/s" && SystemText.rate(300) == "0 KB/s"
      && SystemText.rate(-5) == "0 KB/s", "网速：不到 1 KB 也写成 KB，不会出现负数")
check(SystemText.percent(0.234) == "23%" && SystemText.percent(1.7) == "100%" && SystemText.percent(-1) == "0%", "百分比")
check(SystemText.cpuUsage(previous: [100, 50, 800, 0], current: [130, 70, 850, 0]) == 0.5, "CPU：忙的计数占一半 → 50%")
check(SystemText.cpuUsage(previous: [UInt32.max - 9, 0, 0, 0], current: [10, 0, 20, 0]) == 0.5, "CPU：计数绕回 0 也算得对")
check(SystemText.cpuUsage(previous: [1, 1, 1, 1], current: [1, 1, 1, 1]) == nil && SystemText.cpuUsage(previous: [], current: [1, 2, 3, 4]) == nil,
      "CPU：没有变化或没取到 → 先不显示")
check(SystemText.counterDelta(UInt32.max - 99, 100) == 200, "网卡计数过 4 GB 绕回 0，差值照样对")
check(SystemText.memoryUsed(internalPages: 1000, purgeablePages: 100, wiredPages: 200, compressedPages: 50, pageSize: 16384)
      == 1150 * 16384, "内存：App 内存（去掉可清除的）+ 联动 + 被压缩")
check(SystemText.cpuLine(0.23) == "CPU　23%" && SystemText.cpuLine(nil) == "CPU　…"
      && SystemText.memoryLine(used: UInt64(18.2 * 1_073_741_824), total: 24 * 1_073_741_824) == "内存　已用 18.2 GB / 共 24 GB"
      && SystemText.networkLine(down: 1_200_000, up: 80_000) == "网速　↓ 1.2 MB/s　↑ 80 KB/s" && SystemText.networkLine(down: nil, up: nil) == "网速　…"
      && SystemText.diskLine(available: 312_000_000_000) == "磁盘　剩余 312 GB", "系统状态每一行的文字")
check(SystemText.batteryLine(percent: 86, charging: true, charged: false, onPower: true) == "电池　86%，充电中"
      && SystemText.batteryLine(percent: 100, charging: false, charged: true, onPower: true) == "电池　100%，已充满"
      && SystemText.batteryLine(percent: 80, charging: false, charged: false, onPower: true) == "电池　80%，接着电源"
      && SystemText.batteryLine(percent: 54, charging: false, charged: false, onPower: false) == "电池　54%，用电池", "电池的几种状态")
check(SystemText.remaining(42 * 60) == "还剩 42 分钟" && SystemText.remaining(41 * 60 + 10) == "还剩 42 分钟"
      && SystemText.remaining(72 * 60) == "还剩 1 小时 12 分钟" && SystemText.remaining(120 * 60) == "还剩 2 小时"
      && SystemText.remaining(59) == "还剩不到 1 分钟", "防休眠还剩多久")

// MARK: 标注升级：点没点中、挪动、拉伸
check(EditGeometry.distance(CGPoint(x: 5, y: 3), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)) == 3
      && EditGeometry.distance(CGPoint(x: 13, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)) == 5
      && EditGeometry.distance(CGPoint(x: 3, y: 4), toSegment: .zero, .zero) == 5, "点到线段的距离（线段外面算到端点）")
check(EditGeometry.distance(CGPoint(x: 10, y: 12), toPolyline: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]) == 2
      && EditGeometry.distance(.zero, toPolyline: []) == .infinity, "点到画笔折线的距离")
let outline = CGRect(x: 0, y: 0, width: 100, height: 60)
check(EditGeometry.distance(CGPoint(x: 50, y: 30), toRectOutline: outline) == 30
      && EditGeometry.distance(CGPoint(x: 2, y: 30), toRectOutline: outline) == 2
      && EditGeometry.distance(CGPoint(x: 103, y: 64), toRectOutline: outline) == 5, "框：只认四条边附近，框里面的空白不算点中")
check(abs(EditGeometry.distance(CGPoint(x: 100, y: 30), toEllipseOutline: outline) - 0) < 0.5
      && abs(EditGeometry.distance(CGPoint(x: 50, y: 30), toEllipseOutline: outline) - 30) < 0.5, "椭圆：认那一圈，中心不算")
check(EditGeometry.bounds(of: [CGPoint(x: 5, y: 9), CGPoint(x: -3, y: 2), CGPoint(x: 7, y: 4)]) == CGRect(x: -3, y: 2, width: 10, height: 7)
      && EditGeometry.bounds(of: []).isNull, "一串点的外框")
check(EditGeometry.scale([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20)], from: CGRect(x: 0, y: 0, width: 10, height: 20),
                         to: CGRect(x: 100, y: 100, width: 30, height: 10)) == [CGPoint(x: 100, y: 100), CGPoint(x: 130, y: 110)],
      "拉伸画笔：所有点等比例搬到新外框")
check(EditGeometry.scale([CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 10)], from: CGRect(x: 5, y: 0, width: 0, height: 10),
                         to: CGRect(x: 15, y: 0, width: 4, height: 20)) == [CGPoint(x: 17, y: 0), CGPoint(x: 17, y: 20)],
      "拉伸一条竖直线：横向只平移，不除以 0")

// MARK: 截图美化、贴图转翻（台阶 13）
check(BeautifyMath.padding(for: CGSize(width: 800, height: 500), level: .medium) == 50
      && BeautifyMath.padding(for: CGSize(width: 100, height: 60), level: .medium) == 28
      && BeautifyMath.padding(for: CGSize(width: 3000, height: 2000), level: .medium) == 90, "美化留白：按短边的比例，限制在 28–90 点")
check(BeautifyMath.padding(for: CGSize(width: 800, height: 500), level: .small) < BeautifyMath.padding(for: CGSize(width: 800, height: 500), level: .medium)
      && BeautifyMath.padding(for: CGSize(width: 800, height: 500), level: .medium) < BeautifyMath.padding(for: CGSize(width: 800, height: 500), level: .large),
      "美化留白：小 < 中 < 大")
let beautyLayout = BeautifyMath.layout(imageSize: CGSize(width: 800, height: 500), style: .standard)
check(beautyLayout.canvas == CGSize(width: 900, height: 600) && beautyLayout.image == CGRect(x: 50, y: 50, width: 800, height: 500),
      "美化：整张图 = 截图 + 两边留白，截图在正中间")
check(BeautifyMath.cornerRadius(for: CGSize(width: 800, height: 500), corner: .large) == 18
      && BeautifyMath.cornerRadius(for: CGSize(width: 40, height: 20), corner: .large) == 5
      && BeautifyMath.cornerRadius(for: CGSize(width: 800, height: 500), corner: .none) == 0, "美化圆角：小截图不会圆得太过")
func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, count: Int) -> [UInt8] { (0..<count).flatMap { _ in [r, g, b, 255] } }
let mostlyOrange = solid(250, 140, 30, count: 70) + solid(255, 255, 255, count: 30)
let orange = BeautifyMath.autoGradient(rgba: mostlyOrange, width: 10, height: 10)
check(orange.name == "自动" && orange.to.0 > orange.to.2 + 0.2 && orange.from.0 < orange.to.0, "自动配色：截图主色是橙色 → 橙色渐变（一头暗一头亮）")
check(BeautifyMath.autoGradient(rgba: solid(120, 120, 120, count: 100), width: 10, height: 10) == BeautifyMath.presets[0],
      "自动配色：黑白灰的截图 → 用默认的蓝紫")
check(abs(BeautifyMath.hue(1, 0, 0) - 0) < 0.001 && abs(BeautifyMath.hue(0, 1, 0) - 1.0 / 3) < 0.001
      && abs(BeautifyMath.hue(0, 0, 1) - 2.0 / 3) < 0.001, "色相：红 0、绿 1/3、蓝 2/3")

// 3 宽 2 高的小图：左上红、右上绿、左下蓝，别的白
func tinyImage() -> CGImage {
    let px: [UInt8] = [255, 0, 0, 255,  0, 255, 0, 255,  0, 255, 0, 255,
                       0, 0, 255, 255,  255, 255, 255, 255,  255, 255, 255, 255]
    let provider = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
/// 读像素，y 从上往下数
func px(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let i = (y * image.width + x) * 4
    return Array(bytes[i..<(i + 3)])
}
let tiny = tinyImage()
let right = PinGeometry.apply(.rotateRight, to: tiny)!
check(right.width == 2 && right.height == 3 && px(right, 1, 0) == [255, 0, 0] && px(right, 0, 0) == [0, 0, 255],
      "贴图向右转：宽高对调，左上的红跑到右上，左下的蓝跑到左上")
let left = PinGeometry.apply(.rotateLeft, to: tiny)!
check(left.width == 2 && left.height == 3 && px(left, 0, 2) == [255, 0, 0], "贴图向左转：左上的红跑到左下")
var spun = tiny
for _ in 0..<4 { spun = PinGeometry.apply(.rotateRight, to: spun)! }
check((0..<3).allSatisfy { x in (0..<2).allSatisfy { y in px(spun, x, y) == px(tiny, x, y) } }, "转四次回到原样")
let flipped = PinGeometry.apply(.flipHorizontal, to: tiny)!
let upside = PinGeometry.apply(.flipVertical, to: tiny)!
check(px(flipped, 2, 0) == [255, 0, 0] && px(upside, 0, 1) == [255, 0, 0]
      && px(PinGeometry.apply(.flipHorizontal, to: flipped)!, 0, 0) == [255, 0, 0], "左右翻、上下翻，翻两次回到原样")
check(PinGeometry.size(after: .rotateLeft, CGSize(width: 300, height: 200)) == CGSize(width: 200, height: 300)
      && PinGeometry.size(after: .flipVertical, CGSize(width: 300, height: 200)) == CGSize(width: 300, height: 200)
      && PinGeometry.rotatedFrame(CGRect(x: 100, y: 100, width: 300, height: 200)) == CGRect(x: 150, y: 50, width: 200, height: 300),
      "转 90° 后贴图以中心为准宽高对调")

// MARK: 连续粘贴的队伍（台阶 14）
var pq = PasteQueue<String>()
pq.append("张三"); pq.append("男")
check(pq.count == 2 && !pq.started && pq.upcoming == "张三", "连续粘贴：还没开始贴时，复制的按顺序排队")
check(pq.take() == "张三" && pq.started && pq.upcoming == "男", "按 ⌘V：拿出第一条，下一条是第二条")
check(!pq.append("28") && pq.count == 2, "开始贴以后再复制的不进队伍（不打乱）")
check(pq.take() == "男" && pq.isFinished && pq.take() == nil, "贴完最后一条就结束，再按也没有了")
var prefilled = PasteQueue(["一", "二", "三"])
check(prefilled.append("四") && prefilled.count == 4, "小窗口里点选的排好后、还没贴之前，新复制的接到队尾")
_ = prefilled
check(ClipboardText.queueStatus(taken: 0, count: 0, upcoming: nil).contains("按顺序复制")
      && ClipboardText.queueStatus(taken: 0, count: 3, upcoming: "张三").hasPrefix("连续粘贴：已排 3 条")
      && ClipboardText.queueStatus(taken: 1, count: 3, upcoming: "这是一段很长很长很长很长的文字内容").hasSuffix("…")
      && ClipboardText.queueStatus(taken: 1, count: 3, upcoming: "男").hasPrefix("连续粘贴 2 / 3")
      && ClipboardText.queueStatus(taken: 3, count: 3, upcoming: nil) == "连续粘贴完了", "连续粘贴小条上的字")

// MARK: 识别加强（台阶 15）
check(TranslateLanguages.defaultTarget(forDetected: "zh-Hans") == "en" && TranslateLanguages.defaultTarget(forDetected: "zh-Hant") == "en"
      && TranslateLanguages.defaultTarget(forDetected: "en") == "zh-Hans" && TranslateLanguages.defaultTarget(forDetected: "ja") == "zh-Hans"
      && TranslateLanguages.defaultTarget(forDetected: nil) == "zh-Hans", "翻译方向：中文翻成英文，别的（认不出也算）翻成中文")
check(TranslateLanguages.name(of: "ja") == "日文" && TranslateLanguages.name(of: "xx") == "xx", "小菜单里的语言名字")
check(TranslateLanguages.same("zh-Hant", "zh-Hans") && !TranslateLanguages.same("en", "zh-Hans") && !TranslateLanguages.same(nil, "en"),
      "源语言和目标是同一种：不用翻")
check(ColorHistory.pack(255, 59, 48) == 0xFF3B30 && ColorHistory.unpack(0xFF3B30) == (255, 59, 48)
      && ColorHistory.pack(300, -5, 10) == 0xFF000A, "颜色存成一个数，取回来不变；越界的夹到 0–255")
var recentColors: [Int] = []
for c in [0x111111, 0x222222, 0x333333] { recentColors = ColorHistory.adding(c, to: recentColors) }
check(recentColors == [0x333333, 0x222222, 0x111111], "最近的颜色：最新的在最前")
recentColors = ColorHistory.adding(0x111111, to: recentColors)
check(recentColors == [0x111111, 0x333333, 0x222222], "同一个颜色再取一次：不记两遍，挪到最前")
for c in 0..<30 { recentColors = ColorHistory.adding(c, to: recentColors) }
check(recentColors.count == ColorHistory.limit && recentColors.first == 29, "最多记 20 个")

// MARK: 设置窗口（台阶 17）：快捷键能不能设、写法，版本号比较
let mine: [(name: String, keyCode: UInt16, modifiers: KeyModifiers)] = [("截图", 18, [.command]), ("录屏", 21, [.command])]
check(HotKeyRules.check(keyCode: 1, modifiers: [.control, .option], others: mine) == .ok, "⌃⌥S：能设")
check(HotKeyRules.check(keyCode: 1, modifiers: [], others: mine) == .needsModifier
      && HotKeyRules.check(keyCode: 1, modifiers: [.shift], others: mine) == .needsModifier, "单按 S、⇧S：不让设（打字时会被截走）")
check(HotKeyRules.check(keyCode: 122, modifiers: [], others: mine) == .ok, "F1 不带修饰键：能设")
check(HotKeyRules.check(keyCode: 21, modifiers: [.command], others: mine) == .sameAs("录屏"), "和 MacKit 自己的撞了：说清楚撞了哪个")
check(HotKeyRules.check(keyCode: 21, modifiers: [.shift, .command], others: mine) == .reserved("系统截图（⇧⌘4）")
      && HotKeyRules.check(keyCode: 8, modifiers: [.command], others: mine) == .reserved("复制（⌘C）")
      && HotKeyRules.check(keyCode: 12, modifiers: [.control, .option, .command], others: mine) == .reserved("MacKit 紧急退出（⌃⌥⌘Q）"),
      "系统和各软件常用的（⇧⌘4、⌘C、紧急退出）：不让设")
check(HotKeyRules.display(keyCode: 18, modifiers: [.shift, .command]) == "⇧⌘1" && HotKeyRules.display(keyCode: 2, modifiers: [.control, .shift]) == "⌃⇧D"
      && HotKeyRules.display(keyCode: 99, modifiers: []) == "F3", "快捷键写法：⌃⌥⇧⌘ 的顺序")
check(AppVersion.isNewer("v2.0.0", than: "1.5.1") && !AppVersion.isNewer("v1.0.0", than: "1.5.1") && !AppVersion.isNewer("1.5.1", than: "1.5.1")
      && AppVersion.isNewer("1.10.0", than: "1.9.9") && AppVersion.isNewer("2", than: "1.9") && AppVersion.parts("v1.2.3-beta") == [1, 2, 3],
      "版本号比较：v2.0.0 比 1.5.1 新，1.10 比 1.9 新，带 v 和后缀也认")

// MARK: 截图加强（台阶 20）
var wideStyle = BeautifyStyle.standard
wideStyle.ratio = .wide
let wide = BeautifyMath.layout(imageSize: CGSize(width: 800, height: 500), style: wideStyle)
check(wide.canvas == CGSize(width: 1067, height: 600) && wide.image == CGRect(x: 134, y: 50, width: 800, height: 500),
      "美化 16:9：截图加留白 900×600，往两边补到 1067×600，截图在正中间")
var squareStyle = BeautifyStyle.standard
squareStyle.ratio = .square
let square = BeautifyMath.layout(imageSize: CGSize(width: 800, height: 500), style: squareStyle)
check(square.canvas == CGSize(width: 900, height: 900) && square.image.origin == CGPoint(x: 50, y: 200), "美化 1:1：往上下补成 900×900")
var tallStyle = BeautifyStyle.standard
tallStyle.ratio = .standard
let tall = BeautifyMath.layout(imageSize: CGSize(width: 400, height: 900), style: tallStyle)
check(abs(tall.canvas.width / tall.canvas.height - 4.0 / 3.0) < 0.01 && tall.canvas.height == 980 && abs(tall.image.midX - tall.canvas.width / 2) <= 0.5,
      "美化 4:3：竖着的截图往两边补，比例对、截图在正中间")
check(BeautifyMath.layout(imageSize: CGSize(width: 800, height: 500), style: .standard) == beautyLayout
      && BeautifyStyle.standard.ratio == .original, "美化原样：和以前一模一样")

// MARK: 录屏自动推近（台阶 21）
check(MouseTrack.normalize(CGPoint(x: 150, y: 350), in: CGRect(x: 100, y: 100, width: 200, height: 400)) == CGPoint(x: 0.25, y: 0.375),
      "鼠标位置换算：屏幕上的点 → 画面里的比例（左上原点）")
check(AutoZoom.segments(clicks: [5, 1, 2.5, 9], maxGap: 2) == [1...2.5, 5...5, 9...9], "点击分段：两次不到 2 秒算一段")
let zc = AutoZoomConfig()
let zseg = AutoZoom.segments(clicks: [1, 2.5], maxGap: 2)
check(AutoZoom.level(at: 0.6, segments: zseg, config: zc) == 0 && abs(AutoZoom.level(at: 0.95, segments: zseg, config: zc) - 0.5) < 1e-9
      && AutoZoom.level(at: 1.2, segments: zseg, config: zc) == 1, "推近：点之前 0.3 秒开始推，半秒推到位")
check(AutoZoom.level(at: 4.4, segments: zseg, config: zc) == 1 && abs(AutoZoom.level(at: 4.9, segments: zseg, config: zc) - 0.5) < 1e-9
      && AutoZoom.level(at: 5.4, segments: zseg, config: zc) == 0, "一段里一直推着；最后一下 2 秒后开始拉回、0.8 秒拉完")
check(AutoZoom.ease(0) == 0 && AutoZoom.ease(1) == 1 && AutoZoom.ease(0.5) == 0.5 && AutoZoom.ease(0.1) < 0.1, "推近拉回有缓动：开头结尾慢")
check(AutoZoom.cropRect(center: CGPoint(x: 0.5, y: 0.5), scale: 2) == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
      && AutoZoom.cropRect(center: CGPoint(x: 0.95, y: 0.02), scale: 2) == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
      && AutoZoom.cropRect(center: CGPoint(x: 3, y: -1), scale: 1) == CGRect(x: 0, y: 0, width: 1, height: 1),
      "放大 2 倍留中间一半；靠边时整块留在画面里；鼠标跑出画面也不出界")
let zsamples = [MouseTrack.Sample(t: 0, x: 0.2, y: 0.2), MouseTrack.Sample(t: 1, x: 0.8, y: 0.6)]
check(AutoZoom.position(at: 0.5, samples: zsamples) == CGPoint(x: 0.5, y: 0.4) && AutoZoom.position(at: 9, samples: zsamples) == CGPoint(x: 0.8, y: 0.6),
      "两次记录之间按直线补鼠标位置")
var jitter: [MouseTrack.Sample] = []
for i in 0...120 { jitter.append(.init(t: Double(i) / 60, x: 0.5 + (i % 2 == 0 ? 0.01 : -0.01), y: 0.5)) }
let calm = AutoZoom.smoothedCenters(samples: jitter, duration: 2, step: 1.0 / 60, follow: 0.25)
check(calm.dropFirst(30).prefix(60).allSatisfy { abs($0.x - 0.5) < 0.002 }, "镜头不跟鼠标的小抖动")
let jump = [MouseTrack.Sample(t: 0, x: 0.1, y: 0.1), MouseTrack.Sample(t: 1, x: 0.1, y: 0.1), MouseTrack.Sample(t: 1.05, x: 0.9, y: 0.9),
            MouseTrack.Sample(t: 4, x: 0.9, y: 0.9)]
let zplan = AutoZoom.plan(MouseTrack(samples: jump, clicks: [1.6], duration: 4), config: zc)
check(abs(zplan.center(at: 1.6).x - 0.9) < 0.05 && zplan.rect(at: 0.5) == CGRect(x: 0, y: 0, width: 1, height: 1)
      && abs(zplan.rect(at: 2).width - 0.5) < 1e-9, "鼠标挪过去再点：点的那一刻镜头已经到了；没推的时候是全景，推到位是一半大")
let trimmedTrack = MouseTrack(samples: jump, clicks: [1.6, 3.5], duration: 4).trimmed(from: 1, to: 3)
check(trimmedTrack.clicks.count == 1 && abs(trimmedTrack.clicks[0] - 0.6) < 1e-9 && trimmedTrack.duration == 2 && trimmedTrack.samples.first?.t == 0, "剪掉开头结尾：鼠标记录跟着剪、时间从 0 算")

// MARK: 屏幕画笔的放大镜（台阶 22）
let lensScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
check(MagnifierMath.lensFrame(mouse: CGPoint(x: 700, y: 500), screen: lensScreen) == CGRect(x: 570, y: 370, width: 260, height: 260)
      && MagnifierMath.lensFrame(mouse: CGPoint(x: 5, y: 975), screen: lensScreen) == CGRect(x: 0, y: 722, width: 260, height: 260),
      "放大镜以鼠标为中心；鼠标到了屏幕角上，放大镜整个还在屏幕里")
check(MagnifierMath.sourceRect(mouse: CGPoint(x: 700, y: 500), screen: lensScreen, pixelsPerPoint: 2, zoom: 2)
      == CGRect(x: 1270, y: 870, width: 260, height: 260), "放大 2 倍：拍鼠标附近 130 点见方（Retina 260 像素）")
check(MagnifierMath.sourceRect(mouse: CGPoint(x: 1510, y: 2), screen: lensScreen, pixelsPerPoint: 2, zoom: 4)
      == CGRect(x: 3024 - 130, y: 0, width: 130, height: 130), "放大 4 倍、鼠标在右下角：拍的那块不出画面")
check(MagnifierMath.zoom(2, step: 1) == 2.25 && MagnifierMath.zoom(3.9, step: 3) == 4 && MagnifierMath.zoom(1.6, step: -1) == 1.5,
      "滚轮一格调 0.25 倍，1.5 到 4 倍之间")

// MARK: 改格式粘贴（台阶 23）
let pdfZh = "这是从 PDF 里复制出来的一段\n中文，每一行都断开了，\n接起来不该多空格。\n\n第二段\n在这里。"
check(ClipboardText.joinLines(pdfZh) == "这是从 PDF 里复制出来的一段中文，每一行都断开了，接起来不该多空格。\n\n第二段在这里。",
      "去掉断行：中文直接接上，空行处还是分段")
let pdfEn = "  The quick brown\r\nfox jumps over   the\r\nwell-\nknown lazy dog.\r\n\r\n\r\nNew paragraph\nhere.  "
check(ClipboardText.joinLines(pdfEn) == "The quick brown fox jumps over the well-known lazy dog.\n\nNew paragraph here.",
      "去掉断行：英文中间加一个空格；\\r\\n 也认；行尾断开的 well- 接上不加空格；好几个空行算一次分段")
check(ClipboardText.joinLines("MacKit 是一个\nMac 工具箱\nfor me") == "MacKit 是一个Mac 工具箱for me",
      "去掉断行：中英混排，挨着中文的不加空格")
check(ClipboardText.squeezeSpaces("\n\n  a   b\t\tc  \n\n\n\n　中文　　空格　\nend  \n\n") == "a b c\n\n中文 空格\nend",
      "去掉多余空格：连着的压成一个、首尾去掉、好几个空行压成一个")
check(ClipboardText.reformat("Hello 世界 iPhone", .upper) == "HELLO 世界 IPHONE"
      && ClipboardText.reformat("Hello 世界 iPhone", .lower) == "hello 世界 iphone", "全大写、全小写：只改英文字母")
check(ClipboardText.capitalizeWords("hello world, don't stop. iPhone 3rd 中文abc") == "Hello World, Don't Stop. IPhone 3rd 中文Abc",
      "每个词首字母大写：别的字母不动，don't 不拆开")
check(ClipboardText.Format.allCases.count == 5 && ClipboardText.reformat("", .joinLines) == "", "五种格式；空的还是空的")

// MARK: 量两个东西的间距、对齐（台阶 24）
let boxA = PixelBox(minX: 100, minY: 100, maxX: 200, maxY: 140)
check(MeasureGap.relation(boxA, PixelBox(minX: 224, minY: 100, maxX: 300, maxY: 140)) == .apart(horizontal: 24, vertical: nil)
      && MeasureGap.relation(PixelBox(minX: 0, minY: 100, maxX: 80, maxY: 140), boxA) == .apart(horizontal: 20, vertical: nil),
      "左右排着：横着的间距（谁在左边都一样）")
check(MeasureGap.relation(boxA, PixelBox(minX: 100, minY: 156, maxX: 200, maxY: 196)) == .apart(horizontal: nil, vertical: 16),
      "上下排着：竖着的间距")
check(MeasureGap.relation(boxA, PixelBox(minX: 230, minY: 150, maxX: 260, maxY: 170)) == .apart(horizontal: 30, vertical: 10),
      "斜着摆：横竖都有")
let card = PixelBox(minX: 50, minY: 50, maxX: 350, maxY: 250)
check(MeasureGap.relation(card, boxA) == .inside(top: 50, bottom: 110, left: 50, right: 150)
      && MeasureGap.relation(boxA, card) == .inside(top: 50, bottom: 110, left: 50, right: 150), "一个在另一个里面：四个边距（先记哪个都一样）")
check(MeasureGap.relation(boxA, PixelBox(minX: 150, minY: 120, maxX: 250, maxY: 160)) == .overlapping
      && MeasureGap.relation(boxA, boxA) == .same, "交叉叠着的、同一个：没有间距")
let aligned = MeasureGap.alignments(boxA, PixelBox(minX: 240, minY: 100, maxX: 300, maxY: 144), near: 8)
check(aligned.contains { $0.edge == .top && $0.diff == 0 } && aligned.contains { $0.edge == .bottom && $0.diff == 4 }
      && aligned.contains { $0.edge == .centerY && $0.diff == 2 } && !aligned.contains { $0.edge == .left },
      "对齐：顶边对齐、底边差 4 像素、中线差 2 像素；离得远的线不算")
check(MeasureGap.alignments(boxA, PixelBox(minX: 120, minY: 300, maxX: 181, maxY: 320), near: 0).map(\.edge) == [.centerX],
      "中线差半个像素也算对齐")
check(MeasureGap.text(.apart(horizontal: 24, vertical: nil), scale: 2) == "12" && MeasureGap.text(.apart(horizontal: 24, vertical: 16), scale: 2) == "横 12、竖 8"
      && MeasureGap.text(.inside(top: 24, bottom: 24, left: 32, right: 31), scale: 2) == "上 12 下 12 左 16 右 15.5"
      && MeasureGap.text(.same, scale: 2) == nil, "复制的文字按点算：12、横 12、竖 8、四个边距")

// MARK: 调色板（台阶 24）
var brand = ColorPalette(name: "品牌色")
check(brand.add(0xFF3B30, name: "主色") && brand.add(0x0A84FF) && !brand.add(0xFF3B30) && brand.colors.count == 2, "调色板：同一个颜色不存两遍")
brand.add(0x34C759, name: "成功 绿")
check(PaletteText.plain(brand) == "品牌色\n主色 #FF3B30\n#0A84FF\n成功 绿 #34C759", "导出纯文字：一行一个，没名字只写 HEX")
check(PaletteText.css(brand) == "/* 品牌色 */\n:root {\n  --主色: #FF3B30;\n  --color-2: #0A84FF;\n  --成功-绿: #34C759;\n}",
      "导出 CSS 变量：名字里的空格换成 -，没名字叫 color-2")
var twins = ColorPalette(name: "重名")
twins.add(0x111111, name: "灰"); twins.add(0x222222, name: "灰")
check(PaletteText.css(twins).contains("--灰: #111111;") && PaletteText.css(twins).contains("--灰-2: #222222;"), "CSS 变量重名：后面加 -2")
let jsonText = PaletteText.json(brand)
let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any]
let parsedColors = parsed?["colors"] as? [[String: Any]]
check(parsed?["name"] as? String == "品牌色" && parsedColors?.count == 3 && parsedColors?[0]["hex"] as? String == "#FF3B30"
      && parsedColors?[0]["rgb"] as? [Int] == [255, 59, 48] && parsedColors?[1]["name"] == nil && parsedColors?[0]["name"] as? String == "主色",
      "导出 JSON：能读回来，名字、HEX、RGB 都对，没名字的不写名字")
check(PaletteText.parseHex("#FF3B30") == 0xFF3B30 && PaletteText.parseHex(" ff3b30 ") == 0xFF3B30 && PaletteText.parseHex("#f00") == 0xFF0000
      && PaletteText.parseHex("#GG0000") == nil && PaletteText.parseHex("12345") == nil, "打 HEX：带不带 #、大小写、三位的都认；不对的不认")
check(PaletteText.uniqueName("品牌色", existing: ["品牌色", "品牌色 2"]) == "品牌色 3" && PaletteText.uniqueName("  ", existing: []) == "我的颜色",
      "新建调色板的名字：重复了加数字，空的叫我的颜色")

print(failures == 0 ? "UNIT TESTS OK" : "UNIT TESTS FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
