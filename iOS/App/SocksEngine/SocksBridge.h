#ifndef SOCKS_BRIDGE_H
#define SOCKS_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Start the embedded microsocks SOCKS5 server bound to 127.0.0.1 on
   `device_port`. Runs the accept loop on its own thread so it never blocks the
   caller. Safe to call once; subsequent calls are no-ops while running.

   Blocks briefly (typically well under 50 ms, at most 1 s) waiting for the
   listen socket to come up, so a failure is reported to the caller instead of
   being silently swallowed by the worker thread.
   Returns 0 if the proxy is up, -1 if it was already running or the worker
   thread could not be created, -2 if the listen socket could not be created
   (port in use, or iOS refused the bind). */
int socksbridge_start(unsigned short device_port);

/* Stop the accept loop and wait for it to exit, then release the listening
   port. Synchronous; afterwards socksbridge_start() may be called again.
   Each in-flight connection is nudged so it unwinds promptly rather than
   lingering for the full idle timeout. */
void socksbridge_stop(void);

/* 1 if the accept loop is live and accepting, 0 otherwise. Use this to detect
   that the proxy died (e.g. iOS reclaimed the socket while backgrounded) and
   needs a restart -- checking a local "we once called start()" flag cannot see
   that. */
int socksbridge_is_running(void);

/* C 侧 `enum microsocks_state` 的当前值（sockssrv.c）：
   0 空闲 / 1 启动中 / 2 接收循环中 / 3 已干净停止 / 4 失败（监听 socket 失效）。
   与 `socksbridge_is_running()` 的区别：后者只看"是否在服务"，这里能区分
   **为什么**停了。Swift 侧在自愈时打印它——4 意味着被系统回收，是故障；
   3 只是我们主动 stop，属正常。 */
int socksbridge_state(void);

#ifdef __cplusplus
}
#endif

#endif /* SOCKS_BRIDGE_H */
