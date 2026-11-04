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

print(failures == 0 ? "UNIT TESTS OK" : "UNIT TESTS FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
