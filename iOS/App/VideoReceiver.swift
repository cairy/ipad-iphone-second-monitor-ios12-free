// VideoReceiver.swift
//
// A minimal iOS-12-compatible receiver for the "OpenDisplay"-style wire
// protocol (see https://github.com/peetzweg/opendisplay). It does NOT
// contain any code copied from that project -- it is a clean-room
// implementation of the same *publicly documented* framing/JSON contract,
// written so it can talk to an unmodified OpenDisplay Mac app.
//
// Wire format observed from the Mac sender:
//   [4-byte big-endian length][payload]
// `payload` is either:
//   - a JSON control message (< 32KB, first byte '{', contains no 0x00 byte)
//   - a raw H.264 Annex-B chunk (may be prefixed by a small JSON "telemetry"
//     blob before the first 00 00 00 01 start code -- we simply skip
//     everything before the first start code)
//
// The PHONE listens (NWListener) on a TCP port; the MAC connects to it.
// That direction is required so the exact same code path works whether the
// connection arrives over Wi-Fi or is tunneled in over the Lightning/USB-C
// cable via macOS's usbmuxd -- from the phone's point of view both look
// like an incoming TCP connection.
//
// Deliberately avoids Combine (@Published/ObservableObject need iOS 13) and
// SwiftUI (iOS 13) so it builds and runs on iOS 12.

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit

protocol VideoReceiverDelegate: AnyObject {
    func videoReceiver(_ receiver: VideoReceiver, statusDidChange status: String)
    func videoReceiver(_ receiver: VideoReceiver, connectedDidChange connected: Bool)
    func videoReceiver(_ receiver: VideoReceiver, videoSizeDidChange size: CGSize)
    /// x/y normalized [0,1] against the Mac's captured display.
    func videoReceiver(_ receiver: VideoReceiver, cursorDidChange point: CGPoint, visible: Bool)
    /// anchor/normSize normalized against the Mac's captured display (see MacSender.pollCursorImage).
    func videoReceiver(_ receiver: VideoReceiver, cursorImageDidChange image: UIImage, anchor: CGPoint, normSize: CGSize)
}

final class VideoReceiver {

    weak var delegate: VideoReceiverDelegate?
    let displayLayer: AVSampleBufferDisplayLayer

    private(set) var videoSize: CGSize = .zero
    private(set) var isConnected = false

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "videoreceiver.queue")
    private var buffer = Data()

    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var port: UInt16 = 9000
    private var lastDataReceived = Date()
    private var watchdogStarted = false

    // Native panel size announced to the Mac in "hello" so it can size the
    // virtual display to match. Set these before calling start().
    var devicePixelsWide: Int = 0
    var devicePixelsHigh: Int = 0
    var deviceScale: Double = 2

    // Stable per-install id (helps the Mac recognize "same device, other
    // transport"); persisted so it survives relaunches.
    static let installID: String = {
        let key = "LegacyPadDisplay.installID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    // MARK: - Lifecycle

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async { self.startListener() }
        if !watchdogStarted {
            watchdogStarted = true
            scheduleWatchdog()
        }
    }

    /// 睡眠：iPad 锁屏/进后台，或 Mac 锁屏联动。向 Mac 广播 `sleeping` 后
    /// 关闭连接与监听 —— Mac 端（opendisplay fork）收到即拆除虚拟显示器
    /// （窗口搬回主屏），并挂一个"等唤醒"会话耐心重拨。唤醒后由
    /// ensureListening() 重新拉起，Mac 的重拨接上即恢复。
    ///
    /// 睡眠期间必须拒绝 9000 连接：如果只关连接不关监听，Mac 的唤醒重拨
    /// 会立刻重建显示器——副屏在没人看的时候"诈尸"。
    func enterSleep() {
        closeSession(announcing: "sleeping", status: "Asleep — resumes on wake")
    }

    /// App 被终止（上滑杀掉）：广播 `closing` 让 Mac 立即结束会话，
    /// 不用干等 10 秒静默宽限。
    func shutDown() {
        closeSession(announcing: "closing", status: "Closed")
    }

    private func closeSession(announcing type: String, status: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                self.connection?.cancel()
                self.connection = nil
                self.listener?.cancel()
                self.listener = nil
                self.resetStreamState()
                self.setConnected(false)
                self.setStatus(status)
            }
            guard let conn = self.connection, conn.state == .ready else {
                finish()   // 没有活连接也要关监听（见上"诈尸"注释）
                return
            }
            self.sendControl(["type": type], on: conn) {
                self.queue.async { finish() }
            }
            // 发送完成回调在垂死链路上可能永不触发，1s 兜底强制收尾。
            self.queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    /// Call when the app returns to the foreground. iOS suspends our queue
    /// while backgrounded (no background networking mode declared), so the
    /// listener/connection can die silently without ever reaching the
    /// `.failed` state that would otherwise trigger startListener()'s own
    /// retry -- leaving the screen stuck on the last decoded frame forever.
    /// Unconditionally tearing down and recreating both here costs a brief
    /// reconnect flicker but guarantees we never stay stuck black.
    func ensureListening() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.resetStreamState()
            self.startListener()
        }
    }

    private func startListener() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true // touch events are tiny packets; don't let Nagle batch them
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                setStatus("Invalid port \(port)")
                return
            }
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }

        // Bonjour advertisement (Wi-Fi discovery only; USB/usbmux connects
        // straight to the port on the phone and never looks at this).
        // NWTXTRecord needs iOS 13; on iOS 12 we advertise without the "id" TXT entry.
        if #available(iOS 13.0, *) {
            var txt = NWTXTRecord()
            txt["id"] = Self.installID
            listener?.service = NWListener.Service(name: UIDevice.current.name,
                                                    type: "_opensidecar._tcp",
                                                    domain: nil, txtRecord: txt)
        } else {
            listener?.service = NWListener.Service(name: UIDevice.current.name,
                                                    type: "_opensidecar._tcp",
                                                    domain: nil)
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            self.connection?.cancel()
            self.connection = conn
            self.resetStreamState()
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.lastDataReceived = Date()
                    self.setConnected(true)
                    self.sendHello(on: conn)
                case .failed, .cancelled:
                    self.setConnected(false)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.setStatus("Listening on :\(self.port)")
            case .failed(let error):
                self.setStatus("Listener failed (\(error)) -- restarting")
                self.queue.asyncAfter(deadline: .now() + 1) {
                    self.listener?.cancel()
                    self.listener = nil
                    self.startListener()
                }
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) > 6 {
                conn.cancel()
                self.connection = nil
                self.setConnected(false)
            }
            self.scheduleWatchdog()
        }
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        displayLayer.flush()
    }

    // MARK: - Outgoing control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        sendControl([
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "id": Self.installID,
            // No "pv" field on purpose: an absent protocol version is
            // defined by the Mac app as protocol 1, which every released
            // OpenDisplay Mac build supports (minSupportedPeer stays at 1).
        ], on: conn)
    }

    /// x/y normalized [0,1] in *decoded video* space, origin top-left.
    func sendTouch(phase: String, x: Double, y: Double) {
        sendControl(["type": "touch", "phase": phase, "x": x, "y": y])
    }

    /// dx/dy in video pixels (natural-scrolling sign, i.e. content follows the fingers).
    func sendScroll(dx: Double, dy: Double) {
        sendControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil,
                             completion: (() -> Void)? = nil) {
        guard let conn = conn ?? connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else {
            completion?()
            return
        }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in completion?() })
    }

    // MARK: - Incoming: read + length-prefixed deframing

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.buffer.append(data)
                self.drainFrames()
            }
            if error != nil { return }
            if isComplete {
                self.setConnected(false)
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames() {
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let lenRange = cursor..<buffer.index(cursor, offsetBy: 4)
            let len = buffer[lenRange].withUnsafeBytes { raw -> Int in
                let b = raw.bindMemory(to: UInt8.self)
                let v = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                return Int(v)
            }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handlePayload(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Payload routing: JSON control vs. H.264 Annex-B

    private func handlePayload(_ data: Data) {
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0) {
            handleControlJSON(data)
            return
        }
        handleAnnexB(data)
    }

    private func handleControlJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ping":
            // Reply so the Mac's liveness check on this connection is happy.
            sendControl(["type": "pong", "t": obj["t"] ?? 0, "mt": Date().timeIntervalSince1970 * 1000])
        case "cursor":
            let visible = (obj["v"] as? Int ?? 0) == 1
            let point = CGPoint(x: obj["x"] as? Double ?? 0, y: obj["y"] as? Double ?? 0)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoReceiver(self, cursorDidChange: point, visible: visible)
            }
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let image = UIImage(data: png),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoReceiver(self, cursorImageDidChange: image, anchor: anchor, normSize: normSize)
            }
        default:
            break // welcome / stats-only messages: nothing to do in this minimal client
        }
    }

    private func handleAnnexB(_ data: Data) {
        // Split on 4-byte start codes (00 00 00 01). Anything before the
        // first start code is telemetry JSON prefix the Mac may prepend --
        // we just discard it since we don't compute end-to-end latency here.
        var nalus: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
        }

        var vclNALUs: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7: // SPS
                if sps != nalu { sps = nalu; formatDesc = nil }
            case 8: // PPS
                if pps != nalu { pps = nalu; formatDesc = nil }
            case 6:
                break // SEI, ignore
            default:
                vclNALUs.append(nalu) // slice data
            }
        }
        if formatDesc == nil, let sps = sps, let pps = pps {
            displayLayer.flush()
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        enqueueFrame(vclNALUs)
    }

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
                if status == noErr, let desc = desc {
                    formatDesc = desc
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let size = CGSize(width: Int(dims.width), height: Int(dims.height))
                    videoSize = size
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.videoReceiver(self, videoSizeDidChange: size)
                    }
                    setStatus("Receiving \(dims.width)x\(dims.height)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data]) {
        guard let formatDesc = formatDesc else { return }

        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
        guard createStatus == noErr, let blockBuffer = blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                           offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)
        guard let sample = sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, statusDidChange: text)
        }
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, connectedDidChange: value)
        }
        if !value { setStatus("Listening on :\(port)") } else { setStatus("Connected") }
    }
}
