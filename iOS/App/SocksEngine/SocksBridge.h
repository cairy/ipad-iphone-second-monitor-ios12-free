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

#ifdef __cplusplus
}
#endif

#endif /* SOCKS_BRIDGE_H */
