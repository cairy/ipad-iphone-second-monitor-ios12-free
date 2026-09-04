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
    /// 当前 SOCKS 引擎。用协议类型持有，便于运行期在两套引擎间切换做 A/B。
    private var socks: SocksProxying = SocksEngine.defaultEngine.makeProxy(port: 9001)
    private var socksEngine: SocksEngine = SocksEngine.defaultEngine
    /// 切换进行中时跳过 ensureListening，避免作用在正在退出的旧引擎上。
    private var isSwappingEngine = false
    /// 当前引擎的自愈令牌。切换引擎时先作废再换新（见 SocksRestartToken 注释），
    /// 用来堵住「看门狗已派发、切换随后开始」这段窗口导致的双引擎抢 9001。
    private var restartToken = SocksRestartToken()
    /// 前台看门狗：周期性自检 SOCKS 监听是否存活，死了就自愈（见 healSocks）。
    private var healthTimer: Timer?
    private let toastLabel = UILabel()
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

        // Bring up the embedded SOCKS5 proxy (microsocks) so the Mac can tunnel
        // traffic through this iPad over USB. Independent of the video listener
        // -- it owns its own thread and is never torn down by the foreground
        // reconnect logic below.
        socks.start()

        // 静音音频保活：锁屏后进程不挂起，9001 的 accept 循环照常调度。
        // 必须在 socks.start() 之后也能正常工作，但放这里与 SOCKS 启动并列，
        // 语义上是"SOCKS 在锁屏后仍要活着"的前置条件。
        AudioKeepAlive.shared.start()

        // Mac 锁屏联动控制通道（9002，仅 loopback，与 SOCKS/视频互不干扰）。
        control.start()

        UIApplication.shared.isIdleTimerDisabled = true

        // Two-finger pan = scroll (like a trackpad).
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(scrollPan)

        // Three-finger long press = 切换 SOCKS 引擎（microsocks <-> hev）。
        //
        // 存在的唯一理由：做规格 2.2 的温度 A/B 对照时，能在真机上直接切，
        // 不用重新编译安装。三指 + cancelsTouchesInView=false 保证正常触控
        // 转发完全不受影响。
        let engineSwap = UILongPressGestureRecognizer(target: self, action: #selector(handleEngineSwap(_:)))
        engineSwap.numberOfTouchesRequired = 3
        engineSwap.cancelsTouchesInView = false
        engineSwap.allowableMovement = 20
        view.addGestureRecognizer(engineSwap)

        setupToast()

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
        }
    }

    deinit {
        healthTimer?.invalidate()
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

    /// 统一的前台自愈入口：引擎切换进行中跳过，避免作用在正在退出的旧引擎上。
    ///
    /// 主线程只做判断和派发。注意健康探针对 `isSwappingEngine` 的检查发生在
    /// 派发**之前**，后台任务真正执行重启时可能已经有切换开始了——那一段由
    /// `restartToken` 兜底（引擎内部会在 stop+start 前再校验一次）。
    private func healSocks() {
        guard !isSwappingEngine else { return }
        socks.ensureListening(restartToken)
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

    // MARK: - SOCKS 引擎切换（仅用于温度 A/B 对照）

    private func setupToast() {
        toastLabel.textColor = .white
        toastLabel.font = .systemFont(ofSize: 15, weight: .medium)
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.backgroundColor = UIColor(white: 0, alpha: 0.75)
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false
        view.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func showToast(_ text: String) {
        toastLabel.text = text
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideToast), object: nil)
        UIView.animate(withDuration: 0.15) { self.toastLabel.alpha = 1 }
        perform(#selector(hideToast), with: nil, afterDelay: 4.0)
    }

    @objc private func hideToast() {
        UIView.animate(withDuration: 0.3) { self.toastLabel.alpha = 0 }
    }

    /// 三指长按触发。切换引擎的耗时步骤全部放到后台队列，避免 stop() 里
    /// 等待 main_from_str 返回时卡住主线程。
    @objc private func handleEngineSwap(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !isSwappingEngine else { return }
        isSwappingEngine = true

        let prev = socksEngine
        let next: SocksEngine = (prev == .microsocks) ? .hev : .microsocks
        let old = socks
        showToast("切换 SOCKS 引擎：\(prev.displayName) → \(next.displayName)…")

        // 立刻作废当前令牌：此刻起，任何已派发到后台的看门狗自愈都不许再把
        // 旧引擎拉起来（否则它会占住 9001，让新引擎的 start 静默失败）。
        // 作废必须在主线程、在派发后台任务之前完成，才有意义。
        restartToken.invalidate()

        DispatchQueue.global(qos: .userInitiated).async {
            old.stop()

            DispatchQueue.main.async {
                let proxy = next.makeProxy(port: 9001)
                let ok = proxy.start()
                self.socks = proxy
                self.socksEngine = next
                // 新引擎配新令牌，看门狗恢复自愈能力。
                self.restartToken = SocksRestartToken()
                self.isSwappingEngine = false
                self.showToast(ok ? "SOCKS 引擎：\(next.displayName) ✓"
                                  : "SOCKS 引擎 \(next.displayName) 启动失败 ✗")
                NSLog("[EngineSwap] %@ -> %@, start ok=%d",
                      old.engineName, next.displayName, ok)
            }
        }
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
