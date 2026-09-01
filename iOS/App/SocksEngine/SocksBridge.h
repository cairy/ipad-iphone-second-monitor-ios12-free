#ifndef SOCKS_BRIDGE_H
#define SOCKS_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Start the embedded microsocks SOCKS5 server bound to 127.0.0.1 on
   `device_port`. Runs the (never-returning) accept loop on its own thread so
   it never blocks the caller. Safe to call once; subsequent calls are no-ops
   while running.
   Returns 0 if the bridge thread was launched, -1 if it was already running
   or the worker thread could not be created. */
int socksbridge_start(unsigned short device_port);

/* Best-effort stop. microsocks runs an infinite accept loop and exposes no
   teardown path, so this only clears the "running" flag; the worker thread is
   reaped by process exit. Provided for API symmetry. */
void socksbridge_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* SOCKS_BRIDGE_H */
