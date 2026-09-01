#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mac_socks_bridge.py — 纯标准库实现的 USB/usbmuxd TCP 桥（iproxy 等价物，零依赖）

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
"""

import argparse
import plistlib
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


def _pump(src: socket.socket, dst: socket.socket):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.close()
            except OSError:
                pass


def handle_client(local: socket.socket, device_id: int, device_port: int):
    try:
        tunnel = open_device_tunnel(device_id, device_port)
    except RuntimeError as e:
        print(f"[bridge] 隧道建立失败：{e}")
        local.close()
        return
    print(f"[bridge] 已桥接 本机连接 -> 设备 :{device_port}")
    t1 = threading.Thread(target=_pump, args=(local, tunnel), daemon=True)
    t2 = threading.Thread(target=_pump, args=(tunnel, local), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


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
    listener.bind((args.host, args.local))
    listener.listen(64)
    print(f"[bridge] 监听 {args.host}:{args.local}，等待连接（Ctrl-C 退出）...")

    try:
        while True:
            local, addr = listener.accept()
            print(f"[bridge] 本地连接来自 {addr}")
            threading.Thread(
                target=handle_client,
                args=(local, device_id, args.device),
                daemon=True,
            ).start()
    except KeyboardInterrupt:
        print("\n[bridge] 收到中断，退出")
    finally:
        listener.close()


if __name__ == "__main__":
    main()
