import AppKit
import Carbon.HIToolbox

/// "MKit"，用来认出是我们自己注册的快捷键
private let hotKeySignature: OSType = 0x4D4B_6974

/// 全局快捷键。用 Carbon 的 RegisterEventHotKey，不需要"辅助功能"权限。
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var combos: [UInt32: HotKeyCombo] = [:]
    /// 设置窗口里正在录新的快捷键：MacKit 自己的快捷键先全部摘掉（台阶 17），免得按 ⌘1 直接截了图
    private(set) var isSuspended = false
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// 注册成功返回编号；失败返回 nil（通常是被别的软件占用）
    func register(_ combo: HotKeyCombo, action: @escaping @MainActor () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         EventHotKeyID(signature: hotKeySignature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.hotkey.error("register \(combo.display, privacy: .public) failed, status \(status)")
            return nil
        }
        refs[id] = ref
        actions[id] = action
        combos[id] = combo
        if isSuspended { UnregisterEventHotKey(ref); refs[id] = nil }
        Log.hotkey.notice("registered \(combo.display, privacy: .public) as #\(id)")
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
        combos[id] = nil
    }

    /// 先全部摘掉（记着是哪些）
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    /// 摘掉的全部挂回去
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for (id, combo) in combos {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: hotKeySignature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[id] = ref }
        }
    }

    /// 自检用：现在挂着几个
    var registeredCount: Int { refs.count }

    /// 自检用：这个组合现在真的挂在系统上没有
    func isRegistered(_ combo: HotKeyCombo) -> Bool {
        combos.contains { refs[$0.key] != nil && $0.value == combo }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == hotKeySignature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            // Carbon 的事件回调就在主线程上
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
        if status != noErr { Log.hotkey.error("InstallEventHandler failed, status \(status)") }
    }
}
