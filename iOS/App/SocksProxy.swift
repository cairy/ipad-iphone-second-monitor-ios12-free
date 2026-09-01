// SocksProxy.swift
//
// Thin Swift wrapper around the embedded microsocks SOCKS5 server
// (see App/SocksEngine). The server is a long-running C accept loop; this
// class exposes a Swift-friendly start/ensureListening API and, crucially,
// keeps it INDEPENDENT of the video listener. ReceiverViewController's
// foreground-reconnect logic tears down and recreates the video NWListener on
// every return to the foreground -- if the SOCKS server lived on that same
// path it would be killed too. Here it owns its own lifecycle.

import Foundation

final class SocksProxy {

    private let devicePort: UInt16
    private var started = false
    private let lock = NSLock()

    /// `devicePort` is the TCP port microsocks listens on, inside the iPad.
    /// The Mac side forwards to it over USB via usbmuxd (see mac_socks_bridge.py).
    init(devicePort: UInt16 = 9001) {
        self.devicePort = devicePort
    }

    /// Launch the SOCKS server exactly once. Idempotent and thread-safe.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        socksbridge_start(devicePort)
        started = true
    }

    /// Called from the app's will-enter-foreground hook. The SOCKS server runs
    /// on its own thread and is intentionally NOT recreated here (microsocks
    /// has no teardown path); this is a no-op once started. If iOS reclaimed
    /// the listening socket during a long background, re-launching the app
    /// recovers it -- acceptable for a second-monitor app that's used live.
    func ensureListening() {
        start()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        socksbridge_stop()
        started = false
    }
}
