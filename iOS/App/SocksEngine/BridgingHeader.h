#ifndef LEGACYPADDISPLAY_BRIDGING_HEADER_H
#define LEGACYPADDISPLAY_BRIDGING_HEADER_H

// Exposes the embedded microsocks C API to Swift.
#import "SocksBridge.h"

// hev-socks5-server (iOS/Vendor/HevSocks5Server.xcframework).
// 头文件由 xcframework 的 Headers/ 目录提供，Xcode 会自动加入搜索路径。
// 若这里报 "file not found"，说明 framework 依赖没挂上（见 project.yml）。
//
// ⚠️ main_from_str 是**两参数**：
//    int hev_socks5_server_main_from_str(const unsigned char *str, unsigned int len);
#import "hev-main.h"

#endif /* LEGACYPADDISPLAY_BRIDGING_HEADER_H */
