// AudioKeepAlive.swift
//
// 静音音频保活：让进程在 iPad 锁屏后继续运行，SOCKS 监听（9001）不因挂起而死。
//
// 原理：iOS 对持有 `audio` background mode 且正在渲染音频的进程不挂起。
// 这里循环播放一段程序生成的静音 WAV，成本约等于零（数据全 0，DAC 路径
// 空转），换来的是锁屏后 microsocks/hev 的 accept 循环照常调度。
//
// 对其他音频的影响：category 用 .playback + .mixWithOthers —— 与音乐/
// 播客混音共存，不独占、不打断、不 duck。用户放歌时我们只是混进去一段
// 静音，听感零变化。
//
// 副作用（已知、可接受）：
//  - 控制中心"正在播放"卡片可能出现本 App（playback session 的自然结果）；
//  - 音频硬件路径常开，耗电小幅增加（相比继续解码视频流的耗电可忽略）；
//  - App Store 审核可能问询后台音频用途（本项目 sideload 分发，无影响）。

import AVFoundation

final class AudioKeepAlive {

    static let shared = AudioKeepAlive()
    private init() {}

    private var player: AVAudioPlayer?
    private var started = false
    private let lock = NSLock()

    /// 启动保活。幂等；失败只打日志不抛错 —— 保活是增益项，绝不能反过来
    /// 弄死 App 启动（失败时行为退回原状：锁屏即挂起）。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playback 是后台音频的必要条件；.mixWithOthers 保证不抢占
            // 用户的音乐/播客。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[AudioKeepAlive] audio session 配置失败：\(error)（保活未启用）")
            return
        }

        guard let url = Self.writeSilentWav() else {
            NSLog("[AudioKeepAlive] 静音 WAV 生成失败（保活未启用）")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1          // 无限循环
            p.volume = 1.0                // 数据本身是静音，音量无意义，保持默认
            p.prepareToPlay()
            p.play()
            player = p
            started = true
            NSLog("[AudioKeepAlive] 静音音频保活已启动（锁屏后进程不挂起，9001 持续可连）")
        } catch {
            NSLog("[AudioKeepAlive] 播放器创建失败：\(error)（保活未启用）")
            return
        }

        // 电话/Siri 等打断结束后恢复播放，否则被系统趁虚挂起。
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            let optionRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
            if options.contains(.shouldResume) {
                player?.play()
                NSLog("[AudioKeepAlive] 打断结束，已恢复保活播放")
            }
        }
    }

    /// 在 tmp 下生成 1 秒 22050Hz/16bit/单声道 的静音 WAV（约 43 KB）。
    /// 每次启动重新生成，避免依赖 bundle 资源（xcodegen 工程少配一项）。
    private static func writeSilentWav() -> URL? {
        let sampleRate = 22050
        let seconds = 1
        let numSamples = sampleRate * seconds
        let dataSize = numSamples * 2   // 16 bit = 2 bytes/sample
        let pcm = Data(repeating: 0, count: dataSize)

        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + dataSize))     // RIFF 块大小
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16)                        // fmt 块大小
        le16(1)                         // PCM
        le16(1)                         // 单声道
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2))    // byte rate = rate * mono * 2
        le16(2)                         // block align
        le16(16)                        // bits per sample
        data.append(contentsOf: Array("data".utf8))
        le32(UInt32(dataSize))
        data.append(pcm)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keepalive-silence.wav")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("[AudioKeepAlive] WAV 写入失败：\(error)")
            return nil
        }
    }
}
