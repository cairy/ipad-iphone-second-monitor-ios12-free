#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mac_socks_bridge.py — 纯标准库实现的 USB/usbmuxd TCP 桥（iproxy 等价物，零依赖）

把本机 127.0.0.1:<local> 的 TCP 端口，经 macOS 系统 usbmuxd 桥接到
已通过 USB 连接的 iOS 设备上的 TCP 端口 <device>。
在本项目里，<device> 即 iPad 上 microsocks 监听的 :9001，本机 <local> 取 1080。

为什么需要它：
    Mac 没有 IP 层路由到 iPad，只能通过 usbmuxd（USB 多路复用守护进程）做 TCP 隧道。
    OpenDisplay 也是 usbmuxd 的客户端，二者共用系统 usbmuxd，互不干扰；
    本脚本完全不触碰 Mac 端 OpenDisplay 程序。

用法：
    python3 mac_socks_bridge.py --local 1080 --device 9001 [--udid <IPAD_UDID>]
    # 多台设备同时连 Mac 时，必须用 --udid 锁定同一台 iPad，否则会连到"第一个找到的设备"。

协议参考：usbmuxd plist 协议
    ListDevices -> 选 DeviceID（优先 USB 连接）
    Connect(DeviceID, PortNumber) -> 成功后该 socket 即设备端口的透明管道
    注意：Connect 的 PortNumber 须为网络字节序（大端），即 htons(port)。

实现说明（v2，性能与稳定性）：
    转发层从「每连接 2 线程」改为「单线程 selectors 事件循环」。
    原实现下 64 个并发连接 = 128 个 Python 线程争抢 GIL，线程切换本身的
    开销就吃掉了不少吞吐；事件循环下全程单线程，只在有数据可读/可写时才
    工作，且天然支持数百并发。

    两个方向的转发彼此独立、各有缓冲区：对端写满时只暂停「喂它」的那个
    方向，不会像阻塞式 sendall 那样把反向数据也一起卡住（队头阻塞）。
    这一点在 USB 隧道上尤其重要，因为 usbmuxd 管道经常瞬间写满。

    此外：所有 TCP socket 开启 TCP_NODELAY（Nagle 在高延迟隧道上会引入
    数十毫秒级的延迟，参见 iOS/App/SocksEngine/server.c 中的说明），
    并支持 USB 拔插后自动重新解析 DeviceID。

要求 Python 3.7+（selectors 模块）。类型注解使用了 PEP 604 语法，
故在 3.10 以下运行需 `from __future__ import annotations`，已在下方引入。
"""

from __future__ import annotations   # 让 `str | None` 注解在 3.7~3.9 也不报错

import argparse
import errno
import plistlib
import selectors
import socket
import struct
import sys
import threading
import time

USBMUXD_SOCKET = "/var/run/usbmuxd"   # macOS 系统 usbmuxd 的 Unix 域套接字

# usbmuxd plist 协议帧头：length(含头总长), version, 帧类型, tag —— 小端 4×int32
# 注意：帧类型在 plist 协议里**永远是 8**（表示"这是一条 plist 消息"），
# 真正的语义（ListDevices / Connect）写在 plist 正文的 MessageType 里。
# 绝不能把 Connect 写成头类型 2，否则 usbmuxd 报 BAD_COMMAND(Result 1)。
_HEADER = struct.Struct("<iiii")
_VERSION = 1
_MSG_PLIST = 8

RECV_SIZE = 64 * 1024        # 单次 recv 的块大小
BUF_LIMIT = 256 * 1024       # 单方向积压上限；达到后停止从对端读取（背压）
SOCK_BUFSIZE = 256 * 1024    # 内核收发缓冲区建议值
CONNECT_TIMEOUT = 5.0        # 建立 usbmuxd 隧道的超时（秒）


def _frame(payload: bytes, message_type: int = _MSG_PLIST, tag: int = 1) -> bytes:
    # usbmuxd 的 length 字段是「整条消息总长（含 16 字节头）」，
    # 不是 payload 长度。写错会导致请求被截断、返回空 DeviceList。
    return _HEADER.pack(16 + len(payload), _VERSION, message_type, tag) + payload


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("usbmuxd 连接意外关闭")
        buf += chunk
    return buf


def _recv_plist(sock: socket.socket) -> dict:
    # 注意：usbmuxd 响应头的 length 字段是「整条消息总长（含 16 字节头）」，
    # 不是 payload 长度。已读完 16 字节头，剩余 payload = total - 16。
    header = _recv_exact(sock, _HEADER.size)
    total, _, _, _ = _HEADER.unpack(header)
    payload = _recv_exact(sock, total - _HEADER.size)
    return plistlib.loads(payload)


def list_devices() -> list:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(CONNECT_TIMEOUT)
    s.connect(USBMUXD_SOCKET)
    try:
        req = plistlib.dumps({
            "ClientVersionString": "mac_socks_bridge",
            "MessageType": "ListDevices",
            "ProgName": "mac_socks_bridge",
        })
        s.sendall(_frame(req))
        return _recv_plist(s).get("DeviceList", []) or []
    finally:
        s.close()


def pick_device(udid: str | None):
    """返回 (device_id, serial)。udid 为空时优先选 USB 设备。"""
    devices = list_devices()
    # ConnectionType 在 Properties 子字典里，不在顶层
    def conn_type(d):
        return d.get("Properties", {}).get("ConnectionType")
    usb = [d for d in devices if conn_type(d) == "USB"]
    candidates = usb or devices
    if not candidates:
        raise RuntimeError(
            "未发现任何已连接的 iOS 设备。\n"
            "  · 请确认 USB 数据线已插紧（部分充电线不支持数据传输）\n"
            "  · 在 iPad 上解锁屏幕，并点选弹出的「信任此电脑」\n"
            "  · 若已信任，尝试重新插拔 USB 线\n"
            "  · 注意：锁屏状态或未信任的设备不会出现在 usbmuxd 列表中\n"
            "    （即使 Mac 在 USB 总线上看得到它）——这是正常现象"
        )
    if udid:
        for d in candidates:
            props = d.get("Properties", {})
            if props.get("SerialNumber") == udid or props.get("UDID") == udid:
                return d["DeviceID"], udid
        serials = [d.get("Properties", {}).get("SerialNumber") for d in candidates]
        raise RuntimeError(f"未找到 UDID={udid} 的设备；当前可见：{serials}")
    d = candidates[0]
    serial = d.get("Properties", {}).get("SerialNumber")
    return d["DeviceID"], serial


def open_device_tunnel(device_id: int, device_port: int) -> socket.socket:
    """对 usbmuxd 发起 Connect；成功后返回的 socket 即设备端口的透明管道。"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(CONNECT_TIMEOUT)
    s.connect(USBMUXD_SOCKET)
    # PortNumber 必须是网络字节序（大端），等价于 htons(port)
    port_net = ((device_port << 8) & 0xFF00) | (device_port >> 8)
    req = plistlib.dumps({
        "ClientVersionString": "mac_socks_bridge",
        "MessageType": "Connect",
        "DeviceID": device_id,
        "PortNumber": port_net,
        "ProgName": "mac_socks_bridge",
    })
    s.sendall(_frame(req))
    resp = _recv_plist(s)
    if resp.get("MessageType") != "Result" or resp.get("Number", -1) != 0:
        s.close()
        raise RuntimeError(f"usbmuxd Connect 失败：{resp}")
    return s


def tune_tcp(sock: socket.socket) -> None:
    """TCP 调优：关 Nagle、放大内核缓冲区。

    Nagle 会把小包攒到收到上一个 ACK 再发，叠加对端的延迟 ACK 定时器，
    在 USB 隧道这种高延迟链路上可带来数十毫秒级的额外延迟，
    直接影响 HTTP 请求头 / TLS 握手 / 心跳包的响应速度。
    Unix 域套接字（usbmuxd 侧）不支持这些选项，忽略即可。
    """
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass  # 非 TCP（usbmuxd 的 AF_UNIX），无此项
    for opt in (socket.SO_SNDBUF, socket.SO_RCVBUF):
        try:
            sock.setsockopt(socket.SOL_SOCKET, opt, SOCK_BUFSIZE)
        except OSError:
            pass


class DeviceResolver:
    """缓存 DeviceID，并在设备消失/更换后自动重新解析。

    旧实现在启动时取一次 DeviceID 就固定不变：一旦 USB 被拔插，usbmuxd 会
    给同一台设备分配新的 DeviceID，之后所有 Connect 都会失败，而脚本只会
    打印错误、进程照常存活、端口照常监听 —— 对外表现为「代理还活着但每条
    连接都失败」的假活状态。这里在首次 Connect 失败时作废缓存并重新解析。
    """

    def __init__(self, udid: str | None):
        self._udid = udid
        self._device_id: int | None = None
        self._lock = threading.Lock()

    def get(self) -> int:
        with self._lock:
            if self._device_id is None:
                self._device_id, serial = pick_device(self._udid)
                self._serial = serial
            return self._device_id

    def invalidate(self) -> None:
        with self._lock:
            self._device_id = None

    @property
    def serial(self):
        return getattr(self, "_serial", None)


class Tunnel:
    """一条桥接连接：本机 TCP socket <-> usbmuxd 设备管道。

    两个方向各有独立缓冲区，互不阻塞：
        buf_ld  从本机收到、待发往设备
        buf_dl  从设备收到、待发往本机
    """

    __slots__ = ("local", "dev", "buf_ld", "buf_dl",
                 "eof_local", "eof_dev", "flushed_ld", "flushed_dl")

    def __init__(self, local: socket.socket, dev: socket.socket):
        self.local = local
        self.dev = dev
        self.buf_ld = b""
        self.buf_dl = b""
        self.eof_local = False
        self.eof_dev = False
        self.flushed_ld = False   # 已 shutdown(dev, SHUT_WR)
        self.flushed_dl = False   # 已 shutdown(local, SHUT_WR)

    @property
    def finished(self) -> bool:
        return (self.eof_local and not self.buf_ld
                and self.eof_dev and not self.buf_dl)


class Bridge:
    def __init__(self, resolver: DeviceResolver, device_port: int,
                 verbose: bool = False):
        self.resolver = resolver
        self.device_port = device_port
        self.verbose = verbose
        self.sel = selectors.DefaultSelector()
        self.tunnels: set[Tunnel] = set()
        self.connections = 0
        self.reconnects = 0

    # ---------------------------------------------------------------- 事件循环
    def serve_forever(self, listener: socket.socket) -> None:
        self.sel.register(listener, selectors.EVENT_READ, None)
        while True:
            events = self.sel.select(timeout=1.0)
            for key, mask in events:
                if key.data is None:          # 监听 socket -> 新连接
                    self._accept(listener)
                else:
                    self._service(key.data, key.fileobj, mask)
            self._reap()

    def _accept(self, listener: socket.socket) -> None:
        try:
            local, _ = listener.accept()
        except OSError:
            return
        local.setblocking(False)
        tune_tcp(local)

        # 建立到设备的隧道。失败（多半是设备被拔掉）时作废 DeviceID 并重试一次。
        for attempt in (1, 2):
            try:
                device_id = self.resolver.get()
                dev = open_device_tunnel(device_id, self.device_port)
                break
            except (RuntimeError, OSError) as e:
                if attempt == 1:
                    self.resolver.invalidate()
                    self.reconnects += 1
                    self._log(f"隧道建立失败（{e}），重新解析设备后重试")
                    continue
                self._log(f"隧道建立失败，放弃该连接：{e}")
                try:
                    local.close()
                except OSError:
                    pass
                return

        dev.setblocking(False)
        tune_tcp(dev)
        t = Tunnel(local, dev)
        self.tunnels.add(t)
        self.connections += 1
        # 初始状态：两侧缓冲区皆空，故都只等可读；随后交由 _update_interest 调整。
        self.sel.register(local, selectors.EVENT_READ, t)
        self.sel.register(dev, selectors.EVENT_READ, t)
        self._update_interest(t)
        if self.verbose:
            self._log(f"桥接新连接（累计 {self.connections}，"
                      f"当前 {len(self.tunnels)}）")

    def _service(self, t: Tunnel, sock, mask: int) -> None:
        READ, WRITE = selectors.EVENT_READ, selectors.EVENT_WRITE
        # 一条隧道的两路 socket（local / dev）可能同时出现在同一次 select()
        # 返回的 events 列表里。若本次循环里先处理的一路已经把整条隧道关闭
        # （_close 会同时注销并 close 两个 socket，再把 t 从 self.tunnels 丢弃），
        # 后处理的这路事件所对应的 t 已失效，其 socket fd 已是 -1。此时若继续走到
        # _update_interest -> _set_interest -> sel.get_key(sock) 会抛
        # "Invalid file descriptor: -1"，进而炸掉整个事件循环。
        # 用「t 是否已不在 self.tunnels」来短路跳过这种残留事件。
        if t.finished or t not in self.tunnels:
            return
        try:
            if sock is t.local:
                if mask & READ:
                    self._read(t, t.local, is_local=True)
                if mask & WRITE:
                    if not self._write(t, t.local, is_to_dev=False):
                        self._close(t)
                        return
            else:
                if mask & READ:
                    self._read(t, t.dev, is_local=False)
                if mask & WRITE:
                    if not self._write(t, t.dev, is_to_dev=True):
                        self._close(t)
                        return
        except OSError as e:
            if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                self._close(t)
                return
        self._propagate_eof(t)
        if t.finished:
            self._close(t)
            return
        self._update_interest(t)

    def _read(self, t: Tunnel, sock, is_local: bool) -> None:
        try:
            data = sock.recv(RECV_SIZE)
        except (ConnectionResetError, BrokenPipeError, OSError):
            data = b""
        if not data:                      # EOF
            if is_local:
                t.eof_local = True
            else:
                t.eof_dev = True
            return
        if is_local:
            t.buf_ld += data
        else:
            t.buf_dl += data

    def _write(self, t: Tunnel, dst, is_to_dev: bool) -> bool:
        """把对应方向的缓冲区尽量写出。返回 False 表示连接已坏。"""
        if is_to_dev:
            buf, attr = t.buf_ld, "buf_ld"
        else:
            buf, attr = t.buf_dl, "buf_dl"
        if not buf:
            return True
        try:
            n = dst.send(buf)
        except (BrokenPipeError, ConnectionResetError):
            return False
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                return True
            return False
        setattr(t, attr, buf[n:])
        return True

    def _propagate_eof(self, t: Tunnel) -> None:
        """一端读完且已转发干净时，半关闭对端，让对方能收尾并关闭。

        不做这一步的话，"发完请求就关闭写端、等待响应"的客户端会一直挂到
        对端超时 —— 这正是 HTTP 的常见行为。
        """
        if t.eof_local and not t.buf_ld and not t.flushed_ld:
            try:
                t.dev.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            t.flushed_ld = True
        if t.eof_dev and not t.buf_dl and not t.flushed_dl:
            try:
                t.local.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            t.flushed_dl = True

    def _set_interest(self, sock, ev: int, t: Tunnel) -> None:
        """注册/更新/退订某个 socket 的监听事件。

        selectors 不允许 events=0（会抛 ValueError），所以「暂时无事可做」
        必须表达为退订，而不是注册一个空事件集。
        """
        # 双保险：若 socket 已被关闭（fd == -1），get_key 会抛
        # "Invalid file descriptor: -1"。这里在调用 get_key 之前直接跳过，
        # 避免上游守卫（t not in self.tunnels）万一漏判时仍炸循环。
        if sock.fileno() < 0:
            return
        try:
            self.sel.get_key(sock)
            registered = True
        except (KeyError, ValueError):
            # ValueError 说明 socket 已被关闭（fd == -1），按"未注册"处理
            registered = False
        try:
            if ev:
                if registered:
                    self.sel.modify(sock, ev, t)
                else:
                    self.sel.register(sock, ev, t)
            elif registered:
                self.sel.unregister(sock)
        except (KeyError, ValueError, OSError):
            self._close(t)

    def _update_interest(self, t: Tunnel) -> None:
        """按两侧缓冲区的状态，动态调整监听的事件（背压的关键）。

        一侧积压到上限就停止从它的对端读取，于是对端 TCP 窗口关闭、
        发送方自然降速 —— 这就是背压。两侧事件同时为空只可能发生在
        finished 时，此时连接已在别处被回收。
        """
        READ, WRITE = selectors.EVENT_READ, selectors.EVENT_WRITE
        # 本机 socket：还能收（对端未 EOF 且待发区没积压满）就读；
        #            有待发往本机的数据就等可写。
        ev = 0
        if not t.eof_local and len(t.buf_ld) < BUF_LIMIT:
            ev |= READ
        if t.buf_dl:
            ev |= WRITE
        self._set_interest(t.local, ev, t)

        ev = 0
        if not t.eof_dev and len(t.buf_dl) < BUF_LIMIT:
            ev |= READ
        if t.buf_ld:
            ev |= WRITE
        self._set_interest(t.dev, ev, t)

    def _close(self, t: Tunnel) -> None:
        for sock in (t.local, t.dev):
            try:
                self.sel.unregister(sock)
            except (KeyError, ValueError, OSError):
                pass
            try:
                sock.close()
            except OSError:
                pass
        self.tunnels.discard(t)

    def _reap(self) -> None:
        for t in [x for x in self.tunnels if x.finished]:
            self._close(t)

    def _log(self, msg: str) -> None:
        print(f"[bridge] {msg}", flush=True)


def main():
    ap = argparse.ArgumentParser(
        description="经 USB/usbmuxd 把本机端口桥接到 iOS 设备端口（纯标准库 iproxy 等价物）")
    ap.add_argument("--local", type=int, default=1080, help="本机监听端口（默认 1080）")
    ap.add_argument("--device", type=int, default=9001, help="设备侧端口（默认 9001，即 microsocks）")
    ap.add_argument("--host", default="127.0.0.1", help="本机绑定地址（默认仅回环 127.0.0.1）")
    ap.add_argument("--udid", default=None, help="指定设备 UDID（多设备同时连接时必填）")
    ap.add_argument("--list", action="store_true",
                    help="仅列出当前可见设备及其 UDID 后退出（用于获取 --udid 参数）")
    ap.add_argument("--wait", action="store_true",
                    help="未检测到设备时持续轮询，直到 iPad 解锁/信任后出现再继续")
    ap.add_argument("--verbose", action="store_true",
                    help="打印每条连接与统计信息（默认关闭：高并发下 print 的隐式锁"
                         "本身就会成为瓶颈，且会把终端刷满）")
    args = ap.parse_args()

    if args.list:
        devices = list_devices()
        if not devices:
            print("[bridge] 未发现设备。请解锁 iPad 并点选「信任此电脑」后重试。")
        else:
            print(f"[bridge] 发现 {len(devices)} 台设备：")
        for d in devices:
            props = d.get("Properties", {})
            udid = props.get("UDID") or props.get("SerialNumber")
            print(f"  DeviceID={d.get('DeviceID')}  UDID={udid}  "
                  f"ConnectionType={props.get('ConnectionType')}")
        sys.exit(0)

    device_id, serial = None, None
    if args.wait:
        while True:
            try:
                device_id, serial = pick_device(args.udid)
                break
            except RuntimeError:
                print("[bridge] 暂未检测到设备，等待中（请解锁 iPad 并点选「信任此电脑」）...",
                      file=sys.stderr)
                time.sleep(3)
    else:
        try:
            device_id, serial = pick_device(args.udid)
        except RuntimeError as e:
            print(f"[bridge] 错误：{e}", file=sys.stderr)
            sys.exit(1)
    print(f"[bridge] 选定设备 DeviceID={device_id} Serial={serial} -> 设备端口 :{args.device}")

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    listener.bind((args.host, args.local))
    listener.listen(128)
    listener.setblocking(False)
    print(f"[bridge] 监听 {args.host}:{args.local}，等待连接（Ctrl-C 退出）...")
    print("[bridge] 转发模式：单线程事件循环 + 双向独立缓冲（--verbose 可看连接日志）")

    bridge = Bridge(DeviceResolver(args.udid), args.device, verbose=args.verbose)
    try:
        bridge.serve_forever(listener)
    except KeyboardInterrupt:
        print("\n[bridge] 收到中断，退出")
    finally:
        listener.close()


if __name__ == "__main__":
    main()
