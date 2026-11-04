import AppKit
import Darwin
import IOKit.ps

/// 从系统读 CPU、内存、网卡、磁盘、电池（只读，不要任何权限）
enum SystemStats {
    /// CPU 计数：用户、系统、空闲、低优先级（开机以来累计）
    static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    /// 已使用内存（和活动监视器同一个算法），字节
    static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var pageSize: vm_size_t = 0
        guard r == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return SystemText.memoryUsed(internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
                                     wiredPages: UInt64(stats.wire_count), compressedPages: UInt64(stats.compressor_page_count),
                                     pageSize: UInt64(pageSize))
    }

    static var memoryTotal: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// 每块网卡（Wi-Fi、有线，名字是 en 开头的）收发的字节数。不算本机内部的回环、VPN 的虚拟网卡（免得同一份流量算两遍）
    static func networkCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let raw = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        return result
    }

    /// 磁盘可用空间（和访达显示的"可用"一致）
    static func diskAvailable() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    struct Battery: Equatable {
        let percent: Int
        let charging: Bool
        let charged: Bool
        let onPower: Bool
    }

    /// 电池；台式机没有电池就是 nil
    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maxCapacity > 0 ? Int((Double(current) / Double(maxCapacity) * 100).rounded()) : current
            return Battery(percent: percent, charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           charged: d[kIOPSIsChargedKey] as? Bool ?? false,
                           onPower: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

/// 系统状态积木：MacKit 菜单最上面几行显示 CPU、内存、网速、磁盘、电池；菜单开着时每秒刷新。
/// 不占菜单栏位置（2026-11-04 拍板：你的菜单栏图标已经排到刘海旁边了）
@MainActor
final class SystemStatusTool: ToolModule {
    private var cpuItem: NSMenuItem?
    private var memoryItem: NSMenuItem?
    private var networkItem: NSMenuItem?
    private var diskItem: NSMenuItem?
    private var batteryItem: NSMenuItem?
    private var timer: Timer?
    private var lastSampleAt: Date?
    private var lastCPU: [UInt32]?
    private var lastNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private(set) var cpu: Double?
    private(set) var down: Double?
    private(set) var up: Double?

    func activate() {}

    func menuItems() -> [NSMenuItem] {
        // 上次取样太久以前（菜单关着时不取样），算出来的是很长一段时间的平均，不准：重新起头，半秒后再出数
        if let last = lastSampleAt, Date().timeIntervalSince(last) > 3 { cpu = nil; down = nil; up = nil; lastCPU = nil; lastNet = [:] }
        sample()
        var items: [NSMenuItem] = []
        let cpu = line(), memory = line(), network = line(), disk = line()
        items += [cpu, memory, network, disk]
        cpuItem = cpu
        memoryItem = memory
        networkItem = network
        diskItem = disk
        if SystemStats.battery() != nil {
            let battery = line()
            items.append(battery)
            batteryItem = battery
        } else {
            batteryItem = nil
        }
        items.append(ActionMenuItem("打开活动监视器（看是哪个软件在占）") { Self.openActivityMonitor() })
        refreshTitles()
        return items
    }

    /// 菜单打开、关上（AppDelegate 告诉我们）：开着时每秒刷新，关着就停，不白费电
    func menuOpened() {
        timer?.invalidate()
        let first = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.tick()
                let every = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
                RunLoop.main.add(every, forMode: .common)          // 菜单开着时也要跑
                self.timer = every
            }
        }
        RunLoop.main.add(first, forMode: .common)
        timer = first
    }

    func menuClosed() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        sample()
        refreshTitles()
    }

    /// 取一次样；和上一次比，算出 CPU 使用率和网速
    func sample() {
        let now = Date()
        let ticks = SystemStats.cpuTicks()
        if let ticks, let lastCPU, let usage = SystemText.cpuUsage(previous: lastCPU, current: ticks) { cpu = usage }
        lastCPU = ticks
        let net = SystemStats.networkCounters()
        if let last = lastSampleAt, !lastNet.isEmpty {
            let dt = now.timeIntervalSince(last)
            if dt > 0.2 {
                var rx: UInt64 = 0, tx: UInt64 = 0
                for (name, c) in net {
                    guard let old = lastNet[name] else { continue }
                    rx += SystemText.counterDelta(old.rx, c.rx)
                    tx += SystemText.counterDelta(old.tx, c.tx)
                }
                down = Double(rx) / dt
                up = Double(tx) / dt
            }
        }
        lastNet = net
        lastSampleAt = now
    }

    var lines: [String] {
        [cpuItem, memoryItem, networkItem, diskItem, batteryItem].compactMap { $0?.attributedTitle?.string }
    }

    private func refreshTitles() {
        set(cpuItem, SystemText.cpuLine(cpu))
        if let used = SystemStats.memoryUsed() { set(memoryItem, SystemText.memoryLine(used: used, total: SystemStats.memoryTotal)) }
        set(networkItem, SystemText.networkLine(down: down, up: up))
        if let free = SystemStats.diskAvailable() { set(diskItem, SystemText.diskLine(available: free)) }
        if let b = SystemStats.battery() {
            set(batteryItem, SystemText.batteryLine(percent: b.percent, charging: b.charging, charged: b.charged, onPower: b.onPower))
        }
    }

    private func line() -> NSMenuItem {
        let item = ActionMenuItem("…") { Self.openActivityMonitor() }
        item.toolTip = "点一下打开活动监视器"
        return item
    }

    /// 数字用等宽字体，每秒变化时不会左右抖
    private func set(_ item: NSMenuItem?, _ text: String) {
        guard let item, item.attributedTitle?.string != text else { return }
        let size = NSFont.menuFont(ofSize: 0).pointSize
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)])
    }

    static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// 排窗口小抄：macOS 15 自带窗口平铺，MacKit 只是写在菜单里提醒你（2026-11-04 拍板：不自己做窗口吸附）
@MainActor
final class WindowTipsTool: ToolModule {
    static let lines = [
        "拖窗口到屏幕左右边缘 = 半屏，拖到四个角 = 四分之一屏",
        "🌐⌃←  🌐⌃→  🌐⌃↑  🌐⌃↓　放到左 / 右 / 上 / 下半屏",
        "🌐⌃F　铺满　　🌐⌃C　居中　　🌐⌃R　恢复原来的大小",
        "🌐⌃⇧←　当前窗口放左边，上一个用的窗口放右边",
        "🌐 是键盘左下角的地球键（fn）",
        "菜单栏「窗口 → 移动与调整大小」里也都有",
    ]

    func activate() {}

    func menuItems() -> [NSMenuItem] {
        let sub = NSMenu()
        for line in Self.lines { sub.addItem(.info(line)) }
        let item = NSMenuItem(title: "排窗口（系统自带的快捷键）", action: nil, keyEquivalent: "")
        item.submenu = sub
        return [item]
    }
}
