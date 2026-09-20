#!/usr/bin/env python3
"""FWD UDP（UDP-in-TCP）可用性探测 —— 验证 UDP 能否经 iPad 隧道中转。

用法（bridge 已在 1080 监听、iPad App 在前台时）：

    python3 tools/fwd_udp_probe.py                         # 默认 1080 / 223.5.5.5 / baidu.com
    python3 tools/fwd_udp_probe.py --dns 114.114.114.114 --name qq.com
    python3 tools/fwd_udp_probe.py --port 1080 --tcp-check  # 附带 TCP 对照

为什么要这个脚本：
    usbmuxd 是伪 TCP 隧道，标准 SOCKS5 `UDP ASSOCIATE`（CMD=0x03）返回的 UDP
    中继地址在这条链路上必然不通。hev 的私有扩展 `FWD UDP`（CMD=0x05）把 UDP
    报文封装进已有的 SOCKS5 TCP 连接里，usbmuxd 完全无感，上层就拿到了 UDP。
    本脚本直接对上游 SOCKS5 端口发 CMD=0x05 并做一次真实 DNS 往返，用来判定
    这条链路是否真的可用——不需要 utun、不需要 entitlement、不依赖 hev-tunnel。

协议（hev-socks5-core 的 "UDP in TCP" 扩展）：

    请求：VER(5) CMD(0x05) RSV(0) ATYP DST.ADDR DST.PORT
    中继帧：MSGLEN(2) | HDRLEN(1) | ATYP | DST.ADDR | DST.PORT | DATA

⚠️ 实测校正（2026-09-07，iPad 端 hev-socks5-server）：
    上游 README 写 "MSGLEN: The total length of the UDP relay message [MSGLEN, DATA]"，
    按"总长"封装会**静默超时无回包**。实测 MSGLEN 应为 **纯 DATA 的长度**；
    HDRLEN 仍为 MSGLEN(2)+HDRLEN(1)+ATYP(1)+ADDR(4)+PORT(2) = 10（IPv4）。
    回包同理：MSGLEN = 载荷长度，HDRLEN = 10。
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys

SOCKS_VER = 5
CMD_UDP_IN_TCP = 0x05
CMD_CONNECT = 0x01
ATYP_IPV4 = 0x01

REP_TEXT = {
    0: "成功", 1: "general failure", 2: "not allowed", 3: "network unreachable",
    4: "host unreachable", 5: "connection refused", 6: "ttl expired",
    7: "command not supported", 8: "address type not supported",
}


def dns_query(name: bytes) -> bytes:
    """构造一条最小可用的 DNS A 记录查询。"""
    return (b"\x12\x34" + b"\x01\x00" + b"\x00\x01" + b"\x00\x00" * 3
            + b"".join(bytes([len(p)]) + p for p in name.split(b".") if p)
            + b"\x00" + b"\x00\x01\x00\x01")


def _handshake(sock: socket.socket) -> bool:
    sock.sendall(bytes([SOCKS_VER, 1, 0]))          # 无认证
    return sock.recv(2) == b"\x05\x00"


def _read_bind(sock: socket.socket, atyp: int) -> None:
    if atyp == ATYP_IPV4:
        sock.recv(4 + 2)
    elif atyp == 0x03:
        sock.recv(1 + sock.recv(1)[0] + 2)
    elif atyp == 0x04:
        sock.recv(16 + 2)


def fwd_udp(host: str, port: int, dns_ip: str, name: bytes, timeout: float) -> int:
    """经 SOCKS5 FWD UDP 发一次 DNS 查询。返回 0=成功。"""
    s = socket.create_connection((host, port), timeout=timeout)
    try:
        if not _handshake(s):
            print("  握手失败"); return 1
        s.sendall(bytes([SOCKS_VER, CMD_UDP_IN_TCP, 0, ATYP_IPV4])
                  + socket.inet_aton("0.0.0.0") + struct.pack(">H", 0))
        head = s.recv(4)
        rep, atyp = head[1], head[3]
        if rep != 0:
            print("  FWD UDP 被拒：REP=%d（%s）" % (rep, REP_TEXT.get(rep, "?")))
            return 1
        print("  FWD UDP 已建立（REP=0，iPad 端支持该扩展）")
        _read_bind(s, atyp)

        payload = dns_query(name)
        body = bytes([ATYP_IPV4]) + socket.inet_aton(dns_ip) + struct.pack(">H", 53)
        hdrlen = 2 + 1 + len(body)                   # 10（IPv4）
        # MSGLEN = DATA 长度（实测），不是总长
        s.sendall(struct.pack(">H", len(payload)) + bytes([hdrlen]) + body + payload)
        print("  已发 DNS 查询 %s -> %s:53（%d 字节）" % (name.decode(), dns_ip, len(payload)))

        s.settimeout(timeout)
        r = s.recv(4096)
        msl = struct.unpack(">H", r[:2])[0]
        hl = r[2]
        data = r[hl:]
        anc = struct.unpack(">H", data[6:8])[0] if len(data) > 8 else -1
        print("  ✅ 回包 %d 字节（MSGLEN=%d HDRLEN=%d 载荷=%d DNS 应答数=%d）"
              % (len(r), msl, hl, len(data), anc))
        print("  UDP 经隧道往返成功")
        return 0
    except socket.timeout:
        print("  ❌ 超时：未收到回包")
        return 1
    finally:
        s.close()


def tcp_check(host: str, port: int, ip: str, timeout: float) -> int:
    """TCP 对照：证明隧道与目标本身可达，用于区分「网络不通」和「FWD UDP 不通」。"""
    s = socket.create_connection((host, port), timeout=timeout)
    try:
        if not _handshake(s):
            print("  握手失败"); return 1
        s.sendall(bytes([SOCKS_VER, CMD_CONNECT, 0, ATYP_IPV4])
                  + socket.inet_aton(ip) + struct.pack(">H", 53))
        h = s.recv(4)
        if h[1] != 0:
            print("  CONNECT 失败 REP=%d（%s）" % (h[1], REP_TEXT.get(h[1], "?")))
            return 1
        _read_bind(s, h[3])
        q = dns_query(b"example.com")
        s.sendall(struct.pack(">H", len(q)) + q)     # DNS over TCP 需 2 字节长度前缀
        s.settimeout(timeout)
        r = s.recv(4096)
        print("  ✅ TCP 53 通（回包 %d 字节）→ 目标可达" % len(r))
        return 0
    except socket.timeout:
        print("  ❌ TCP 53 超时")
        return 1
    finally:
        s.close()


def main() -> int:
    ap = argparse.ArgumentParser(description="FWD UDP（UDP-in-TCP）可用性探测")
    ap.add_argument("--host", default="127.0.0.1", help="SOCKS5 监听地址（默认 127.0.0.1）")
    ap.add_argument("--port", type=int, default=1080, help="SOCKS5 端口（bridge 默认 1080）")
    ap.add_argument("--dns", default="223.5.5.5", help="UDP 目标 DNS（默认 223.5.5.5）")
    ap.add_argument("--name", default="baidu.com", help="查询域名（默认 baidu.com）")
    ap.add_argument("--timeout", type=float, default=6.0, help="超时秒数（默认 6）")
    ap.add_argument("--tcp-check", action="store_true", help="附加 TCP 53 对照")
    a = ap.parse_args()

    rc = 0
    if a.tcp_check:
        print("① TCP 对照（证明链路与目标可达）")
        rc |= tcp_check(a.host, a.port, a.dns, a.timeout)
        print("② FWD UDP")
    else:
        print("① FWD UDP")
    rc |= fwd_udp(a.host, a.port, a.dns, a.name.encode(), a.timeout)
    return rc


if __name__ == "__main__":
    sys.exit(main())
