#include "SocksBridge.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Defined in sockssrv.c (renamed from `main` for the embedded build). */
extern int microsocks_main(int argc, char **argv);
/* Lifecycle hooks added for the embedded build; see sockssrv.c. */
extern void microsocks_request_stop(void);
extern int microsocks_is_running(void);
extern int microsocks_state(void);

static pthread_t g_thread;
static volatile int g_running = 0;

/* microsocks_main takes (argc, argv); pthread_create hands it a single void*,
   so we capture the args in static storage and call it from a thin shim. The
   argv strings live in static storage so they outlive socksbridge_start(). */
static int g_argc;
static char *g_argv[16];
static char g_listen_ip[16]; /* "127.0.0.1" */
static char g_port[16];      /* decimal port */
static char g_timeout[16];   /* "120" */

/* How long socksbridge_start() waits for the listen socket to come up before
   declaring failure. server_setup() normally returns in a few milliseconds, so
   this is a safety net, not an expected delay. */
#define START_WAIT_USEC   50000 /* poll interval */
#define START_WAIT_TRIES  20    /* 20 * 50ms = 1s worst case */

static void *socksbridge_main_thread(void *unused) {
    (void)unused;
    microsocks_main(g_argc, g_argv);
    /* The loop only returns now if it was asked to stop or hit a fatal error;
       either way we are no longer running. Cleared here rather than in
       socksbridge_stop() so the flag stays correct if the loop ever dies on
       its own. */
    g_running = 0;
    return NULL;
}

int socksbridge_start(unsigned short device_port) {
    if (g_running) return -1;

    snprintf(g_listen_ip, sizeof g_listen_ip, "127.0.0.1");
    snprintf(g_port, sizeof g_port, "%u", device_port);
    /* Idle timeout, seconds. Was 300: a browser's keep-alive sockets then sit
       in the slot table for five minutes after the tab is closed, and 64 of
       them are enough to hit MAX_CLIENTS and stall every new connection. 120 s
       is above any real keep-alive window but reclaims idle slots four times
       faster. */
    snprintf(g_timeout, sizeof g_timeout, "120");

    /* Build argv: microsocks -q -i 127.0.0.1 -p <port> -t 120
       -q        quiet (no stderr logging into the system console)
       -i 127.0.0.1  bind loopback only; usbmuxd reaches the device at
                     localhost, so this is sufficient AND avoids exposing the
                     proxy on the iPad's Wi-Fi interface. If USB tunneling ever
                     fails to connect, switch this to "0.0.0.0".
       -t 120    idle timeout (seconds) so dead connections are reaped. */
    int i = 0;
    g_argv[i++] = "microsocks"; /* argv[0] = program name */
    g_argv[i++] = "-q";
    g_argv[i++] = "-i";
    g_argv[i++] = g_listen_ip;
    g_argv[i++] = "-p";
    g_argv[i++] = g_port;
    g_argv[i++] = "-t";
    g_argv[i++] = g_timeout;
    g_argv[i] = NULL;

    g_argc = i; /* count of non-NULL entries, including argv[0] */

    if (pthread_create(&g_thread, NULL, socksbridge_main_thread, NULL) != 0) {
        return -1;
    }

    /* Wait for the listen socket to actually exist. Previously the return
       value of microsocks_main was unreachable on this thread, so a failed
       server_setup() (port already bound, iOS reclaiming the socket) left the
       Swift side believing the proxy was up while nothing was listening. */
    for (int tries = 0; tries < START_WAIT_TRIES; tries++) {
        if (microsocks_is_running()) {
            g_running = 1;
            return 0;
        }
        if (microsocks_state() == 4 /* MSOCKS_FAILED */) break;
        usleep(START_WAIT_USEC);
    }

    /* Either server_setup() failed outright or it never came up. Take the
       thread back down so a later start() is not rejected as "already
       running". */
    microsocks_request_stop();
    pthread_join(g_thread, NULL);
    g_running = 0;
    return -2;
}

void socksbridge_stop(void) {
    if (!g_running) return;
    microsocks_request_stop();
    /* Now genuinely synchronous: the accept loop polls for the stop flag and
       exits, draining its connections, so the port is free to rebind
       immediately afterwards. This is what makes the Swift-side restart on
       foreground recovery actually work. */
    pthread_join(g_thread, NULL);
    g_running = 0;
}

int socksbridge_is_running(void) {
    return g_running && microsocks_is_running() ? 1 : 0;
}
