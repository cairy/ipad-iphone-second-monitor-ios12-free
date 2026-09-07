// ReceiverViewController.swift
//
// Fullscreen video surface + touch/scroll input forwarding. Deliberately
// plain UIKit (no SwiftUI) so it compiles for iOS 12.

import UIKit
import AVFoundation

final class VideoContainerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

final class ReceiverViewController: UIViewController, VideoReceiverDelegate {

    private let videoView = VideoContainerView()
    private let statusLabel = UILabel()
    private var receiver: VideoReceiver!
    /// Mac 锁屏联动通道（BarKit 经 usbmuxd 发 macLock 消息，端口 9002）。
    private let control = ControlChannel()
    /// 副屏会话状态机的两个输入（见 updateSessionState）：App 是否活跃、
    /// Mac 是否锁屏。两者任一不满足 → 视频会话进入睡眠（Mac 拆显示器）。
    private var appActive = true
    private var macLocked = false
    /// SOCKS5 引擎（hev-socks5-server，见 HevSocksProxy）。
    private let socks = HevSocksProxy(port: 9001)
    /// 前台看门狗：周期性自检 SOCKS 监听是否存活，死了就自愈（见 healSocks）。
    private var healthTimer: Timer?

    /// 静音保活当前是否处于开启态（与 AudioKeepAlive.isRunning 对齐）。
    /// 只在状态翻转时驱动 AudioKeepAlive，避免每帧电池通知都重start。
    private var keepAliveRunning = false
    private var lastVideoSize: CGSize = .zero

    // Cursor sprite: positioned/sized in normalized [0,1] Mac-display space,
    // updated at control-message rate (fast) independent of the ~30ms video path.
    private let cursorLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }()
    private var cursorNormSize: CGSize = .zero
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var cursorVisible = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        videoView.layer.addSublayer(cursorLayer)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        receiver = VideoReceiver(displayLayer: videoView.displayLayer)
        receiver.delegate = self
        control.delegate = self
        // 锁同步回报：把唯一状态机的结果（appActive && !macLocked）发给 Mac，
        // BarKit 面板据此显示"副屏活跃/睡眠"。主线程调用，无锁。
        control.sleepingProvider = { [weak self] in
            guard let self = self else { return true }
            return !(self.appActive && !self.macLocked)
        }

        // Bring up the embedded SOCKS5 proxy (hev-socks5-server) so the Mac can
        // tunnel traffic through this iPad over USB. Independent of the video
        // listener -- it owns its own queue and is never torn down by the
        // foreground reconnect logic below.
        socks.start()

        // 静音音频保活：锁屏后进程不挂起，9001 的 accept 循环照常调度。
        // 门控由电池充电状态驱动（详见 applyKeepAliveForBatteryState）：连着
        // 电源（=连着 Mac/USB）= 需要保活；拔线立即停。
        //
        // 拉起方式 = 乐观开启 + 立即按真实状态校准：先无条件 start 保留"启动即可用"
        // 的原有行为（启动时若 batteryState 尚未就绪为 .unknown，不能因此误杀），
        // 再开监测、注册通知，最后 applyKeepAliveForBatteryState() 把状态收敛到真实值
        // （启动时已拔线则停；充电中则保持；.unknown 则保守保持乐观开启）。
        AudioKeepAlive.shared.start()
        keepAliveRunning = AudioKeepAlive.shared.isRunning

        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification, object: nil)
        applyKeepAliveForBatteryState()

        // Mac 锁屏联动控制通道（9002，仅 loopback，与 SOCKS/视频互不干扰）。
        control.start()

        UIApplication.shared.isIdleTimerDisabled = true

        // Two-finger pan = scroll (like a trackpad).
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(scrollPan)

        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                                name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                                name: UIApplication.didBecomeActiveNotification, object: nil)
        // iPad 自己进后台（回主屏/锁 iPad）：视频会话睡眠（Mac 拆显示器）。
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                                name: UIApplication.didEnterBackgroundNotification, object: nil)
        // App 被杀：广播 closing，让 Mac 立即收会话。
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                                name: UIApplication.willTerminateNotification, object: nil)

        // 看门狗：SOCKS 监听可能在 App 一直停前台时悄悄死掉（锁屏/解锁被系统回收
        // socket、或本次启动绑定就失败）。这两类情况都不会触发 willEnterForeground，
        // 甚至 didBecomeActive 也不保证每次都覆盖，所以周期性探针自愈才是真正的兜底。
        healthTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.healSocks()
            self?.keepAliveTick()
        }
    }

    deinit {
        healthTimer?.invalidate()
    }

    // MARK: - 静音保活门控（电池充电状态驱动）

    /// 电池状态变化回调：连着电源（充电中 / 已充满且连电）= 连着 Mac/USB，
    /// 需要保活让锁屏后进程不挂起；拔线变 .unplugged 立即停。
    ///
    /// batteryState 不区分电源类型（充电器/充电宝也算 .charging/.full），但本
    /// 程序只在连 Mac 用副屏时运行；一旦拔 Mac 停保活，进程失去后台模式被系统
    /// 挂起，后续插充电器也不会再唤醒它 —— 因此"误判常开"仅在"运行中把 Mac
    /// 线换插充电器"这一种窄场景，且只是多耗一点电，无害。
    @objc private func batteryStateChanged() {
        applyKeepAliveForBatteryState()
    }

    private func applyKeepAliveForBatteryState() {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            setKeepAlive(true)
        case .unplugged:
            setKeepAlive(false)
        case .unknown:
            // monitoring 尚未就绪：保守保持现状，不贸然停（避免启动瞬间误杀保活）
            break
        @unknown default:
            setKeepAlive(false)
        }
    }

    /// 保活开关的唯一出口：只在状态翻转时才动 AudioKeepAlive。
    private func setKeepAlive(_ on: Bool) {
        guard on != keepAliveRunning else { return }
        if on {
            AudioKeepAlive.shared.start()
            // 以 AudioKeepAlive 的实际状态为准：start() 内部失败时（session
            // 被电话/Siri 占用、WAV 写不进去）started 仍为 false。这里若记
            // 成 true，后续就不会再尝试续命了。
            keepAliveRunning = AudioKeepAlive.shared.isRunning
            if keepAliveRunning {
                keepAliveLog("USB 已连（充电中）→ 静音保活已开启")
            }
        } else {
            // 先打日志再停保活：stop() 内部 setActive(false) 交出后台资格，系统
            // 可在其后任意时刻挂起进程，日志放在交出资格之后有被漏掉的风险。
            keepAliveLog("已拔线（停止充电）→ 静音保活已停止（进程可被系统挂起）")
            AudioKeepAlive.shared.stop()
            keepAliveRunning = false
        }
    }

    /// 保活续命：start() 失败时（如那一刻 audio session 被电话/Siri 占用）
    /// keepAliveRunning 保持 false，门控只在电池状态翻转时才重试 —— 若一直
    /// 插着电，保活就一直缺席到下次拔插。借已有的 8s 看门狗补一次重试。
    ///
    /// 节流：持续失败时 start() 每次都会 NSLog 一条，8s 一撞会把控制台刷满、
    /// 干扰真机验证时的日志判读。攒够 8 次（约 64s）才重试一次足够。
    private func keepAliveTick() {
        switch UIDevice.current.batteryState {
        case .charging, .full:
            guard !keepAliveRunning else { keepAliveRetryTick = 0; return }
            keepAliveRetryTick += 1
            if keepAliveRetryTick >= 8 {
                keepAliveRetryTick = 0
                setKeepAlive(true)
            }
        case .unplugged, .unknown:
            // .unknown 保守不动，与 applyKeepAliveForBatteryState 保持一致
            keepAliveRetryTick = 0
        @unknown default:
            keepAliveRetryTick = 0
        }
    }
    /// keepAliveTick 的重试节流计数（见该方法注释）。
    private var keepAliveRetryTick = 0

    /// 保活状态变更日志。只走 NSLog（Xcode → Devices → Open Console 可见），
    /// 不落盘。
    ///
    /// 这里原本还有一段写 Library/Caches/keepalive.log 的落盘逻辑，是专为验证
    /// "拔线瞬间门控是否真触发"临时加的脚手架 —— 拔线时 USB 调试通道随之中断，
    /// 实时日志看不到那关键一行，只能先落盘、重插后离线读。已在 2026-09-06
    /// 真机验证通过后移除：它会在 Caches 下只增不减，而系统只在存储告急时才回收。
    /// 若将来还要复验，临时把文件写入加回来即可。
    private func keepAliveLog(_ msg: String) {
        NSLog("[KeepAlive] \(msg)")
    }

    // Backgrounding suspends our networking queue; the listener/connection
    // can die silently without ever telling us, leaving the screen stuck on
    // the last decoded frame. Force a clean reconnect on every return.
    @objc private func appWillEnterForeground() {
        appActive = true
        updateSessionState()
        healSocks()
    }

    // 锁屏 -> 解锁触发的是 didBecomeActive，而不是 willEnterForeground。
    // 不在这里也自愈一次，解锁后监听会一直是死的。
    @objc private func appDidBecomeActive() {
        healSocks()
    }

    // iPad 进后台（锁 iPad / 回主屏）：进程被音频保活撑着不挂起，若视频
    // 会话还活着，Mac 就一直认为副屏存在——窗口留在看不见的屏上，也操作
    // 不了。进入睡眠：广播 sleeping + 关连接关监听，Mac 拆显示器并挂
    // "等唤醒"重拨，回前台自动恢复。
    @objc private func appDidEnterBackground() {
        appActive = false
        updateSessionState()
    }

    // App 被终止（上滑杀掉）：广播 closing，Mac 立即收会话而非等宽限。
    @objc private func appWillTerminate() {
        receiver.shutDown()
    }

    /// 副屏会话唯一状态机：活跃 且 Mac 未锁屏 → 显示器在；否则睡眠。
    /// 所有生命周期/联动入口都汇到这里，避免两路信号互相打架
    /// （如"Mac 解锁但 iPad 还在后台"时显示器诈尸）。
    private func updateSessionState() {
        let shouldStream = appActive && !macLocked
        if shouldStream {
            receiver.ensureListening()
        } else {
            receiver.enterSleep()
        }
        // Mac 锁屏时黑屏兜底（此刻显示器已拆，这层黑只是视觉提示）。
        videoView.isHidden = macLocked
        updateStatusVisibility()
    }

    /// 统一的前台自愈入口。主线程只做派发，探针与重启都在 HevSocksProxy 的
    /// 后台队列里完成（见 `HevSocksProxy.ensureListening`）。
    private func healSocks() {
        socks.ensureListening()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        announcePanel()
        updateCursorLayout()
    }

    /// Positions/sizes the cursor sprite inside the letterboxed video rect.
    /// `cursorNorm`/`cursorNormSize` are normalized [0,1] against the Mac's
    /// captured display (see VideoReceiver's "cursor"/"cursorImg" handling).
    private func updateCursorLayout() {
        let rect = letterboxedContentRect()
        guard cursorNormSize.width > 0, cursorNormSize.height > 0,
              rect.width > 0, rect.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                     width: cursorNormSize.width * rect.width,
                                     height: cursorNormSize.height * rect.height)
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                        y: rect.minY + cursorNorm.y * rect.height)
        CATransaction.commit()
    }

    private func announcePanel() {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        receiver.devicePixelsWide = Int(bounds.width * scale)
        receiver.devicePixelsHigh = Int(bounds.height * scale)
        receiver.deviceScale = Double(scale)
        if !receiverStarted {
            receiverStarted = true
            receiver.start(port: 9000)
        }
    }
    private var receiverStarted = false

    // MARK: - Touch -> "touch" control messages

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "began")
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "moved")
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "ended")
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "ended")
    }

    /// Maps a raw touch point into [0,1] video space, accounting for the
    /// letterboxing that `.resizeAspect` introduces when the decoded frame's
    /// aspect ratio doesn't exactly match the view's.
    private func forwardTouch(_ touches: Set<UITouch>, phase: String) {
        guard let touch = touches.first else { return }
        sendNormalized(touch: touch, phase: phase)
    }

    private func sendNormalized(touch: UITouch, phase: String) {
        let point = touch.location(in: view)
        let contentRect = letterboxedContentRect()
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        let clampedX = min(max(point.x, contentRect.minX), contentRect.maxX)
        let clampedY = min(max(point.y, contentRect.minY), contentRect.maxY)
        let nx = (clampedX - contentRect.minX) / contentRect.width
        let ny = (clampedY - contentRect.minY) / contentRect.height
        receiver.sendTouch(phase: phase, x: Double(nx), y: Double(ny))
    }

    /// The actual rect the decoded video occupies inside `videoView` under
    /// AVLayerVideoGravity.resizeAspect.
    private func letterboxedContentRect() -> CGRect {
        let bounds = videoView.bounds
        guard lastVideoSize.width > 0, lastVideoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let videoAspect = lastVideoSize.width / lastVideoSize.height
        let boundsAspect = bounds.width / bounds.height
        if videoAspect > boundsAspect {
            let height = bounds.width / videoAspect
            let y = (bounds.height - height) / 2
            return CGRect(x: 0, y: y, width: bounds.width, height: height)
        } else {
            let width = bounds.height * videoAspect
            let x = (bounds.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    // MARK: - Two-finger scroll -> "scroll" control messages

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        receiver.sendScroll(dx: Double(translation.x), dy: Double(translation.y))
    }

    // MARK: - VideoReceiverDelegate

    func videoReceiver(_ receiver: VideoReceiver, statusDidChange status: String) {
        statusLabel.text = status
    }

    func videoReceiver(_ receiver: VideoReceiver, connectedDidChange connected: Bool) {
        updateStatusVisibility()
    }

    func videoReceiver(_ receiver: VideoReceiver, videoSizeDidChange size: CGSize) {
        lastVideoSize = size
        updateCursorLayout()
    }

    func videoReceiver(_ receiver: VideoReceiver, cursorDidChange point: CGPoint, visible: Bool) {
        cursorNorm = point
        cursorVisible = visible
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayout()
    }

    func videoReceiver(_ receiver: VideoReceiver, cursorImageDidChange image: UIImage, anchor: CGPoint, normSize: CGSize) {
        cursorLayer.contents = image.cgImage
        cursorLayer.anchorPoint = anchor
        cursorNormSize = normSize
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayout()
    }
}

// MARK: - ControlChannelDelegate（Mac 锁屏联动）

extension ReceiverViewController: ControlChannelDelegate {

    /// Mac 锁屏状态变化 → 交给唯一状态机处理（显示器随之拆/建）。
    func controlChannel(_ channel: ControlChannel, macLockedDidChange locked: Bool) {
        guard macLocked != locked else { return }
        macLocked = locked
        NSLog("[ControlChannel] Mac 侧%@", locked ? "已锁屏 → 副屏显示器拆除" : "已解锁 → 恢复副屏")
        updateSessionState()
    }

    /// 状态条文案唯一出口：Mac 锁屏时显示联动状态（黑屏上能看到"Mac 已锁屏"
    /// 说明联动通道活着），否则跟随连接状态隐藏/显示。
    private func updateStatusVisibility() {
        if macLocked {
            statusLabel.text = "Mac 已锁屏"
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = receiver.isConnected
        }
    }
}
