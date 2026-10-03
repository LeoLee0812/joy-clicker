// JoyClicker：把 Joy-Con 变成 PPT 翻页笔的 macOS 菜单栏小工具（单文件、无第三方依赖）
//
// 做法：IOHIDManager 非独占地读 Joy-Con 的蓝牙 HID 原始报告，切到 0x30 全量模式（约 60Hz 上报），
// 某个键「刚按下」的那一刻，用 CGEvent 给前台 App 发对应的键盘按键（需要辅助功能权限）。
// 不用系统 GameController 框架：它把单只 Joy-Con 当横握小手柄，左手柄甚至认不出来。
// 协议参考 dekuNukem/Nintendo_Switch_Reverse_Engineering；输出节拍、震动编码沿用 LookAsk 在本机的实测结论。

import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.leo.joyclicker", category: "main")
private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// Glint（LookAsk）也直接读 Joy-Con：它在前台时翻页笔让路，它在跑时不往手柄发任何东西
private let glintID = "com.leo.lookask"
private func glintRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: glintID).isEmpty }

// MARK: - 按键与映射

/// 0x30 全量报告第 3、4、5 字节拼成的 24 位按键状态
struct Btn: OptionSet, Hashable {
    let rawValue: UInt32
    // 第 3 字节：右手柄
    static let y = Btn(rawValue: 1 << 0)
    static let x = Btn(rawValue: 1 << 1)
    static let b = Btn(rawValue: 1 << 2)
    static let a = Btn(rawValue: 1 << 3)
    static let rSR = Btn(rawValue: 1 << 4)
    static let rSL = Btn(rawValue: 1 << 5)
    static let r = Btn(rawValue: 1 << 6)
    static let zr = Btn(rawValue: 1 << 7)
    // 第 4 字节：左右共用
    static let minus = Btn(rawValue: 1 << 8)
    static let plus = Btn(rawValue: 1 << 9)
    static let rStick = Btn(rawValue: 1 << 10)
    static let lStick = Btn(rawValue: 1 << 11)
    static let home = Btn(rawValue: 1 << 12)
    static let capture = Btn(rawValue: 1 << 13)
    // 第 5 字节：左手柄
    static let down = Btn(rawValue: 1 << 16)
    static let up = Btn(rawValue: 1 << 17)
    static let right = Btn(rawValue: 1 << 18)
    static let left = Btn(rawValue: 1 << 19)
    static let lSR = Btn(rawValue: 1 << 20)
    static let lSL = Btn(rawValue: 1 << 21)
    static let l = Btn(rawValue: 1 << 22)
    static let zl = Btn(rawValue: 1 << 23)
}

private let btnNames: [(Btn, String)] = [
    (.up, "↑"), (.down, "↓"), (.left, "←"), (.right, "→"), (.x, "X"), (.b, "B"), (.y, "Y"), (.a, "A"),
    (.l, "L"), (.zl, "ZL"), (.r, "R"), (.zr, "ZR"), (.lSL, "SL"), (.lSR, "SR"), (.rSL, "SL"), (.rSR, "SR"),
    (.minus, "−"), (.plus, "+"), (.lStick, "左摇杆按下"), (.rStick, "右摇杆按下"), (.home, "HOME"), (.capture, "截图键"),
]

func describe(_ b: Btn) -> String { btnNames.filter { b.contains($0.0) }.map(\.1).joined(separator: " ") }

/// 虚拟键码（Carbon 的 kVK_*）
enum VK {
    static let left: CGKeyCode = 0x7B
    static let right: CGKeyCode = 0x7C
    static let down: CGKeyCode = 0x7D
    static let up: CGKeyCode = 0x7E
    static let esc: CGKeyCode = 0x35
    static let b: CGKeyCode = 0x0B
    static let p: CGKeyCode = 0x23
    static let f: CGKeyCode = 0x03
    static let ret: CGKeyCode = 0x24
}

/// 真键盘的方向键自带 fn + 小键盘标志，照着带上
let arrow: CGEventFlags = [.maskNumericPad, .maskSecondaryFn]

enum Action: Equatable {
    case key(CGKeyCode, CGEventFlags)
    /// 开始放映：各家快捷键不一样，按前台 App 选
    case startShow
    /// 短按 = 黑屏 / 恢复（B），按住 = 退出放映（Esc）
    case blackOrExit
}

/// 竖握（像遥控器那样）时的按键表：左手柄十字键、右手柄 X B Y A 都按位置当方向键。
/// 放映中 → ↓ 是下一页、← ↑ 是上一页，WPS / PowerPoint / Keynote / Google 幻灯片 / PDF 通用。
/// 截图键、HOME 键不映射：系统「游戏控制器」设置会拿它们截屏、开启动台。
let keymap: [(Btn, Action)] = [
    (.up, .key(VK.up, arrow)), (.down, .key(VK.down, arrow)), (.left, .key(VK.left, arrow)), (.right, .key(VK.right, arrow)),
    (.x, .key(VK.up, arrow)), (.b, .key(VK.down, arrow)), (.y, .key(VK.left, arrow)), (.a, .key(VK.right, arrow)),
    (.zl, .key(VK.right, arrow)), (.zr, .key(VK.right, arrow)),   // 扳机 = 下一页
    (.l, .key(VK.left, arrow)), (.r, .key(VK.left, arrow)),       // 肩键 = 上一页
    (.lSR, .key(VK.right, arrow)), (.rSR, .key(VK.right, arrow)), // 横握时 SR = 下一页
    (.lSL, .key(VK.left, arrow)), (.rSL, .key(VK.left, arrow)),   // 横握时 SL = 上一页
    (.minus, .blackOrExit), (.plus, .blackOrExit),
    (.lStick, .startShow), (.rStick, .startShow),
]

func action(for b: Btn) -> Action? { keymap.first { $0.0 == b }?.1 }

/// 「从头开始放映」的快捷键；不是演示软件就返回 nil（免得在别的 App 里乱按组合键）
func startShowShortcut(for bundleID: String?) -> (CGKeyCode, CGEventFlags)? {
    guard let id = bundleID else { return nil }
    let browsers = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser",
                    "com.brave.Browser", "org.mozilla.firefox"]
    if id == "com.apple.iWork.Keynote" { return (VK.p, [.maskCommand, .maskAlternate]) }   // ⌥⌘P 播放幻灯片
    if id == "com.apple.Preview" { return (VK.f, [.maskCommand, .maskShift]) }             // ⇧⌘F 幻灯片显示
    // ⇧⌘↩：WPS（配置里写的 Shift+Ctrl+Return，Qt 在 Mac 上 Ctrl 就是 ⌘）、PowerPoint、Google 幻灯片都是「从头开始」
    if id.hasPrefix("com.kingsoft.wpsoffice") || id == "com.microsoft.Powerpoint" || browsers.contains(id) {
        return (VK.ret, [.maskCommand, .maskShift])
    }
    return nil
}

/// 给前台 App 发一次按键。组合键要先真的按下修饰键再松开：有的 App 只认系统里的修饰键状态，不看事件上的标志
func tap(_ key: CGKeyCode, _ flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    let mods: [(CGEventFlags, CGKeyCode)] = [(.maskCommand, 0x37), (.maskShift, 0x38), (.maskAlternate, 0x3A), (.maskControl, 0x3B)]
        .filter { flags.contains($0.0) }
    func post(_ k: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down) else { return }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }
    var held: CGEventFlags = []
    for (f, k) in mods { held.insert(f); post(k, true, held) }
    post(key, true, flags)
    post(key, false, flags)
    for (f, k) in mods.reversed() { held.remove(f); post(k, false, held) }
}

// MARK: - 报告解析

struct PadState: Equatable {
    var buttons: Btn
    /// 0 空 … 4 满
    var battery: Int
    var charging: Bool
}

/// 解析 0x30（全量）/ 0x21（子命令回复）报告：第 2 字节高 4 位是电量（最低位 = 在充电），第 3~5 字节是按键
func parseStandard(_ r: [UInt8]) -> PadState? {
    guard r.count >= 6, r[0] == 0x30 || r[0] == 0x21 else { return nil }
    let nib = Int(r[2] >> 4)
    return PadState(buttons: Btn(rawValue: UInt32(r[3]) | UInt32(r[4]) << 8 | UInt32(r[5]) << 16),
                    battery: nib >> 1, charging: nib & 1 == 1)
}

/// 玩家灯当电量格：满 4 格 … 告急 1 格，没电时第 1 格闪
func ledMask(battery: Int) -> UInt8 { [0x10, 0x01, 0x03, 0x07, 0x0F][max(0, min(4, battery))] }

/// 一帧「不震」（振幅 0）
let quietFrame: [UInt8] = [0x00, 0x01, 0x40, 0x40]

/// HD 震动编码，移植自 LookAsk（源自 tomayac/joy-con-webhid）；振幅夹在 0~1，再大伤马达
func encodeRumble(lowFreq: Double, highFreq: Double, amplitude: Double) -> [UInt8] {
    let lf0 = min(max(lowFreq, 40.875885), 626.286133)
    let hf0 = min(max(highFreq, 81.75177), 1252.572266)
    let hf = (Int((32 * log2(hf0 * 0.1)).rounded()) - 0x60) * 4
    let lf = Int((32 * log2(lf0 * 0.1)).rounded()) - 0x40
    let amp = min(max(amplitude, 0), 1)
    var hfAmp: Double
    if amp == 0 { hfAmp = 0 }
    else if amp < 0.117 { hfAmp = (log2(amp * 1000) * 32 - 0x60) / (5 - amp * amp) - 1 }
    else if amp < 0.23 { hfAmp = log2(amp * 1000) * 32 - 0x60 - 0x5C }
    else { hfAmp = (log2(amp * 1000) * 32 - 0x60) * 2 - 0xF6 }
    let hfAmpI = Int(hfAmp.rounded())
    var lfAmp = Int(Double(hfAmpI) * 0.5)
    let parity = lfAmp % 2
    if parity > 0 { lfAmp -= 1 }
    lfAmp = lfAmp >> 1
    lfAmp += 0x40
    if parity > 0 { lfAmp |= 0x8000 }
    return [UInt8(truncatingIfNeeded: hf & 0xFF), UInt8(truncatingIfNeeded: hfAmpI + ((hf >> 8) & 0xFF)),
            UInt8(truncatingIfNeeded: lf + ((lfAmp >> 8) & 0xFF)), UInt8(truncatingIfNeeded: lfAmp & 0xFF)]
}

// MARK: - 单只手柄

final class JoyCon {
    let device: IOHIDDevice
    let name: String
    /// L / R / Pro
    let side: String
    /// 蓝牙地址，当这只手柄的身份
    let serial: String
    var keepAlive = true

    private(set) var state = PadState(buttons: [], battery: -1, charging: false)
    /// 最近一秒收到的 0x30 帧数（探针模式看帧率）
    private(set) var frames = 0
    private(set) var lastPress = uptime()
    var onPress: ((JoyCon, Btn) -> Void)?
    var onRelease: ((JoyCon, Btn) -> Void)?
    var onStatus: (() -> Void)?

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var packet: UInt8 = 0
    /// 待发的输出报告：蓝牙每 ~15ms 才送得出一包，发快了会排队卡主线程，所以走一个 15ms 节拍
    private var queue: [(bytes: [UInt8], sub: Bool)] = []
    private var pump: DispatchSourceTimer?
    private var lastSubAt = 0.0
    private var lastFull = 0.0
    private var lastInit = 0.0
    private var shownLED: UInt8 = 0xFF
    private var greeted = false
    private var timer: Timer?

    init(device: IOHIDDevice, name: String, side: String, serial: String) {
        self.device = device
        self.name = name
        self.side = side
        self.serial = serial
    }

    deinit { buffer.deallocate() }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            Unmanaged<JoyCon>.fromOpaque(ctx).takeUnretainedValue().handle(report, Int(length))
        }, ctx)
        initialize()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        pump?.cancel()
        pump = nil
        queue.removeAll()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, nil, nil)
    }

    /// 退出前同步切回简单模式 0x3F：不然手柄会一直 60Hz 发全量报告，白白耗电
    func restoreSimpleMode() {
        guard !glintRunning() else { return }
        stop()
        var r = [UInt8](repeating: 0, count: 49)
        r[0] = 0x01
        r[1] = packet & 0x0F
        r.replaceSubrange(2..<10, with: quietFrame + quietFrame)
        r[10] = 0x03
        r[11] = 0x3F
        _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(r[0]), r, r.count)
    }

    private func initialize() {
        lastInit = uptime()
        shownLED = 0xFF
        subcommand(0x03, [0x30])   // 输入报告切到 0x30 全量模式
        subcommand(0x48, [0x01])   // 允许震动
    }

    private func handle(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) {
        guard n > 0 else { return }
        if p[0] == 0x3F {
            // 简单模式：手柄刚醒或被别的程序重置了，切回全量模式
            if uptime() - lastInit > 1 { initialize() }
            return
        }
        guard let s = parseStandard(Array(UnsafeBufferPointer(start: p, count: min(n, 12)))) else { return }
        if p[0] == 0x30 {
            lastFull = uptime()
            frames += 1
            if !greeted {
                greeted = true
                buzz([(60, 0.5), (60, 0), (60, 0.5)])   // 连上了：震两下
            }
        }
        let pressed = s.buttons.subtracting(state.buttons)
        let released = state.buttons.subtracting(s.buttons)
        let statusChanged = s.battery != state.battery || s.charging != state.charging
        state = s
        if !pressed.isEmpty {
            lastPress = uptime()
            onPress?(self, pressed)
        }
        if !released.isEmpty { onRelease?(self, released) }
        let mask = ledMask(battery: s.battery)
        if mask != shownLED, !glintRunning() {
            shownLED = mask
            subcommand(0x30, [mask])
        }
        if statusChanged { onStatus?() }
    }

    func takeFrameCount() -> Int {
        defer { frames = 0 }
        return frames
    }

    private func tick() {
        let now = uptime()
        // 看门狗：3 秒没收到全量报告 = 手柄刚醒回到了简单模式，或被别的程序改了模式
        if now - lastFull > 3, now - lastInit > 3 { initialize() }
        // 保活：最后一次按键后的一段时间内，每 2 秒发一帧「不震」，免得讲一页讲久了手柄闲置休眠断开
        let minutes = UserDefaults.standard.object(forKey: "keepAliveMinutes") as? Double ?? 30
        if keepAlive, minutes > 0, now - lastPress < minutes * 60 { rumbleFrame(quietFrame) }
    }

    /// 震一下：每段（毫秒, 振幅），振幅 0 = 停顿
    func buzz(_ segs: [(Double, Double)]) {
        for (ms, amp) in segs {
            let four = amp > 0 ? encodeRumble(lowFreq: 160, highFreq: 320, amplitude: amp) : quietFrame
            for _ in 0..<max(1, Int((ms / 15).rounded())) { rumbleFrame(four) }
        }
        rumbleFrame(quietFrame)
    }

    // MARK: 输出

    private func subcommand(_ id: UInt8, _ args: [UInt8]) {
        var r = [UInt8](repeating: 0, count: 49)
        r[0] = 0x01
        r.replaceSubrange(2..<10, with: quietFrame + quietFrame)
        r[10] = id
        for (i, a) in args.prefix(38).enumerated() { r[11 + i] = a }
        enqueue(r, sub: true)
    }

    private func rumbleFrame(_ four: [UInt8]) {
        enqueue([0x10, 0] + four + four, sub: false)
    }

    private func enqueue(_ bytes: [UInt8], sub: Bool) {
        guard !glintRunning() else { return }   // Glint 在管手柄时不插手
        queue.append((bytes, sub))
        guard pump == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.015, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pumpStep() }
        pump = t
        t.resume()
    }

    private func pumpStep() {
        guard let head = queue.first else {
            pump?.cancel()
            pump = nil
            return
        }
        let now = uptime()
        if head.sub, now - lastSubAt < 0.06 { return }   // 子命令之间至少隔 60ms，连发太快手柄会丢
        queue.removeFirst()
        var r = head.bytes
        r[1] = packet & 0x0F
        packet &+= 1
        let res = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(r[0]), r, r.count)
        if res != kIOReturnSuccess { logger.error("\(self.name, privacy: .public) 发送失败 \(res)") }
        if head.sub { lastSubAt = now }
    }
}

// MARK: - 手柄管理（插拔）

final class JoyManager {
    private let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var pads: [String: JoyCon] = [:]
    var all: [JoyCon] { pads.values.sorted { $0.side < $1.side } }
    var keepAliveSides: Set<String> = ["L", "R", "Pro"]
    var onPress: ((JoyCon, Btn) -> Void)?
    var onRelease: ((JoyCon, Btn) -> Void)?
    var onAttach: ((JoyCon) -> Void)?
    var onDetach: ((JoyCon) -> Void)?
    var onChange: (() -> Void)?

    func start() {
        IOHIDManagerSetDeviceMatching(hid, [kIOHIDVendorIDKey: 0x057E] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hid, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<JoyManager>.fromOpaque(ctx).takeUnretainedValue().attach(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<JoyManager>.fromOpaque(ctx).takeUnretainedValue().detach(dev)
        }, ctx)
        // commonModes：菜单展开时（事件跟踪模式）也照样收手柄
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let res = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        if res != kIOReturnSuccess { logger.error("IOHIDManagerOpen 失败 \(res)") }
    }

    private func key(_ dev: IOHIDDevice) -> String {
        if let s = IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String, !s.isEmpty { return s }
        return String(IOHIDDeviceGetProperty(dev, kIOHIDLocationIDKey as CFString) as? Int ?? 0, radix: 16)
    }

    private func attach(_ dev: IOHIDDevice) {
        let side: String
        switch IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0 {
        case 0x2006: side = "L"
        case 0x2007: side = "R"
        case 0x2009: side = "Pro"
        default: return
        }
        let id = key(dev)
        guard pads[id] == nil else { return }
        let res = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard res == kIOReturnSuccess else {
            logger.error("打开手柄失败 \(res)")
            return
        }
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Joy-Con"
        let pad = JoyCon(device: dev, name: name, side: side, serial: id)
        pad.keepAlive = keepAliveSides.contains(side)
        pad.onPress = { [weak self] p, b in self?.onPress?(p, b) }
        pad.onRelease = { [weak self] p, b in self?.onRelease?(p, b) }
        pad.onStatus = { [weak self] in self?.onChange?() }
        pads[id] = pad
        pad.start()
        logger.notice("\(name, privacy: .public) 已连接")
        onAttach?(pad)
        onChange?()
    }

    private func detach(_ dev: IOHIDDevice) {
        guard let pad = pads.removeValue(forKey: key(dev)) else { return }
        pad.stop()
        logger.notice("\(pad.name, privacy: .public) 已断开")
        onDetach?(pad)
        onChange?()
    }
}

// MARK: - 菜单栏 App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let probe: Bool
    private let pads = JoyManager()
    private var item: NSStatusItem?
    private var paused = UserDefaults.standard.bool(forKey: "paused")
    private var trusted = AXIsProcessTrusted()
    private var axTimer: Timer?
    /// 正按着的 − / +：到点算长按（退出放映），提前松开算短按（黑屏）
    private var holds: [String: DispatchWorkItem] = [:]
    private var longFired: Set<String> = []

    init(probe: Bool, keepAliveSides: Set<String>?) {
        self.probe = probe
        if let keepAliveSides { pads.keepAliveSides = keepAliveSides }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        pads.onPress = { [weak self] p, b in self?.pressed(p, b) }
        pads.onRelease = { [weak self] p, b in self?.released(p, b) }
        pads.onDetach = { [weak self] p in self?.forgetHolds(of: p) }
        if probe {
            startProbe()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        pads.onChange = { [weak self] in self?.refresh() }
        pads.start()
        enableLoginOnce()
        if !trusted {
            // 弹系统的「想要控制这台电脑」授权框；授权状态没有通知可订阅，没授权前每 2 秒看一眼
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self, AXIsProcessTrusted() else { return }
                self.trusted = true
                t.invalidate()
                self.refresh()
            }
        }
        refresh()
    }

    func applicationWillTerminate(_ note: Notification) {
        for pad in pads.all { pad.restoreSimpleMode() }
    }

    // MARK: 按键 → 动作

    private func canSend() -> Bool {
        guard !paused, AXIsProcessTrusted() else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier != glintID
    }

    private func pressed(_ pad: JoyCon, _ btns: Btn) {
        if probe {
            say("\(pad.side) 按下 \(describe(btns))")
            return
        }
        // debug 级不落盘，排查「按了没反应」时用 /usr/bin/log stream --level debug 看
        let ok = canSend()
        logger.debug("\(pad.side, privacy: .public) 按下 \(describe(btns), privacy: .public)\(ok ? "" : "，没发键（暂停 / 没权限 / Glint 在前台）", privacy: .public)")
        guard ok else { return }
        for (b, act) in keymap where btns.contains(b) {
            switch act {
            case .key(let k, let f):
                tap(k, f)
            case .startShow:
                if let (k, f) = startShowShortcut(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
                    tap(k, f)
                } else {
                    pad.buzz([(40, 0.4), (60, 0), (40, 0.4)])   // 前台不是演示软件：震两下表示没动作
                }
            case .blackOrExit:
                let id = "\(pad.serial)#\(b.rawValue)"
                let work = DispatchWorkItem { [weak self, weak pad] in
                    guard let self else { return }
                    self.longFired.insert(id)
                    tap(VK.esc, [])
                    pad?.buzz([(90, 0.6)])   // 退出放映了，震一下告诉你可以松手
                }
                holds[id]?.cancel()
                holds[id] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            }
        }
    }

    private func released(_ pad: JoyCon, _ btns: Btn) {
        if probe {
            say("\(pad.side) 松开 \(describe(btns))")
            return
        }
        for (b, act) in keymap where btns.contains(b) && act == .blackOrExit {
            let id = "\(pad.serial)#\(b.rawValue)"
            guard let work = holds.removeValue(forKey: id) else { continue }
            work.cancel()
            if longFired.remove(id) == nil { tap(VK.b, []) }   // 没到长按：黑屏 / 恢复
        }
    }

    /// 手柄按着键断开了：长按计时作废，免得断线后凭空退出放映
    private func forgetHolds(of pad: JoyCon) {
        for id in holds.keys where id.hasPrefix(pad.serial + "#") { holds.removeValue(forKey: id)?.cancel() }
        longFired = longFired.filter { !$0.hasPrefix(pad.serial + "#") }
    }

    // MARK: 菜单

    private func refresh() {
        guard let button = item?.button else { return }
        let image = NSImage(systemSymbolName: pads.all.isEmpty ? "gamecontroller" : "gamecontroller.fill",
                            accessibilityDescription: "JoyClicker")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = paused || !trusted
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        trusted = AXIsProcessTrusted()
        if pads.all.isEmpty {
            menu.addItem(info("没连上 Joy-Con"))
            menu.addItem(button("打开蓝牙设置…", #selector(openBluetooth)))
        } else {
            for pad in pads.all {
                let lvl = max(0, pad.state.battery)
                let bars = String(repeating: "●", count: lvl) + String(repeating: "○", count: 4 - lvl)
                menu.addItem(info("\(pad.name)　电量 \(bars)\(pad.state.charging ? " 充电中" : "")"))
            }
        }
        if !trusted { menu.addItem(button("⚠️ 去开「辅助功能」权限才能翻页…", #selector(openAccessibility))) }
        menu.addItem(.separator())
        let help = NSMenuItem(title: "按键说明", action: nil, keyEquivalent: "")
        help.submenu = NSMenu()
        for line in [
            "十字键　＝ 方向键：→ ↓ 下一页，← ↑ 上一页",
            "ZL / ZR 扳机　下一页",
            "L / R 肩键　上一页",
            "− / +　短按黑屏（再按恢复），按住 1 秒退出放映",
            "按下摇杆　从头开始放映",
            "右手柄的 X B Y A 按位置当方向键",
            "手柄上亮几格灯 ＝ 剩几格电",
        ] { help.submenu?.addItem(info(line)) }
        menu.addItem(help)
        let pause = button("暂停翻页", #selector(togglePause))
        pause.state = paused ? .on : .off
        menu.addItem(pause)
        let login = button("开机自动启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(button("退出 JoyClicker", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func button(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: "paused")
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            logger.error("开机自启设置失败 \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 第一次从「应用程序」文件夹启动时，默认打开开机自启
    private func enableLoginOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginConfigured"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        d.set(true, forKey: "loginConfigured")
        try? SMAppService.mainApp.register()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openBluetooth() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 探针模式（终端里看手柄事件，不发按键）

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func say(_ s: String) { print("\(clock.string(from: Date())) \(s)") }

    private func startProbe() {
        setvbuf(stdout, nil, _IOLBF, 0)
        say("探针模式：按手柄看输出，Ctrl+C 退出（不发按键）；保活：\(pads.keepAliveSides.sorted().joined(separator: " "))")
        pads.onAttach = { [weak self] p in self?.say("\(p.name) 已连接") }
        pads.onDetach = { [weak self] p in
            self?.forgetHolds(of: p)
            self?.say("\(p.name) 已断开")
        }
        pads.start()
        // 每分钟报一次在线状态和 0x30 帧率
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let parts = self.pads.all.map { "\($0.side) 电量\($0.state.battery) \($0.takeFrameCount() / 60)帧/秒" }
            self.say(parts.isEmpty ? "没有手柄在线" : parts.joined(separator: "，"))
        }
    }
}

// MARK: - 自测（不碰硬件，验证解析和映射）

func selfTest() -> Bool {
    var ok = true
    func check(_ cond: Bool, _ msg: String) {
        print((cond ? "✓ " : "✗ ") + msg)
        if !cond { ok = false }
    }
    var r = [UInt8](repeating: 0, count: 49)
    r[0] = 0x30
    r[2] = 0x8E
    r[5] = 0x04
    let s = parseStandard(r)
    check(s?.buttons == .right, "第 5 字节 0x04 = 左手柄 →")
    check(s?.battery == 4 && s?.charging == false, "电量高 4 位 0x8 = 满格、没在充电")
    r[2] = 0x3E
    check(parseStandard(r)?.battery == 1 && parseStandard(r)?.charging == true, "0x3 = 告急 1 格、在充电")
    r[3] = 0x88
    r[5] = 0x80
    check(parseStandard(r)?.buttons == [.a, .zr, .zl], "第 3 字节 0x88 = A + ZR，第 5 字节 0x80 = ZL")
    r[4] = 0x0B
    check(parseStandard(r)?.buttons.isSuperset(of: [.minus, .plus, .lStick]) == true, "第 4 字节 0x0B = − + 左摇杆按下")
    r[0] = 0x3F
    check(parseStandard(r) == nil, "简单模式 0x3F 报告不当全量报告解析")
    check(action(for: .right) == .key(VK.right, arrow) && action(for: .zl) == .key(VK.right, arrow), "→ 和 ZL 都是下一页（→ 键）")
    check(action(for: .up) == .key(VK.up, arrow) && action(for: .l) == .key(VK.left, arrow), "↑ 发 ↑ 键，L 是上一页（← 键）")
    check(action(for: .a) == .key(VK.right, arrow) && action(for: .x) == .key(VK.up, arrow), "右手柄 A / X 按位置当 → / ↑")
    check(action(for: .minus) == .blackOrExit && action(for: .lStick) == .startShow, "− 黑屏 / 退出，左摇杆按下开始放映")
    check(action(for: .capture) == nil && action(for: .home) == nil, "截图键、HOME 不映射")
    let shift: CGEventFlags = [.maskCommand, .maskShift]
    check(startShowShortcut(for: "com.kingsoft.wpsoffice.mac").map { $0.0 == VK.ret && $0.1 == shift } == true, "WPS 从头放映 ⇧⌘↩")
    check(startShowShortcut(for: "com.apple.iWork.Keynote").map { $0.0 == VK.p && $0.1 == [.maskCommand, .maskAlternate] } == true, "Keynote ⌥⌘P")
    check(startShowShortcut(for: "com.apple.Preview").map { $0.0 == VK.f && $0.1 == shift } == true, "预览 ⇧⌘F")
    check(startShowShortcut(for: "com.electron.lark") == nil && startShowShortcut(for: nil) == nil, "非演示软件不发组合键")
    check(ledMask(battery: 4) == 0x0F && ledMask(battery: 1) == 0x01 && ledMask(battery: 0) == 0x10, "电量 → 玩家灯")
    check(encodeRumble(lowFreq: 160, highFreq: 320, amplitude: 0) == quietFrame, "振幅 0 编码出来正好是「不震」帧")
    print(ok ? "全部通过" : "有失败项")
    return ok
}

// MARK: - 入口

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selfTest() ? 0 : 1) }
var keepAliveSides: Set<String>?
if let i = args.firstIndex(of: "--keepalive"), i + 1 < args.count {
    // 调试用：--keepalive L / R / none，只给指定的手柄保活（对照实验休眠）
    keepAliveSides = Set(args[i + 1].split(separator: ",").map(String.init).filter { $0 != "none" })
}
let app = NSApplication.shared
let delegate = AppDelegate(probe: args.contains("--probe"), keepAliveSides: keepAliveSides)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
