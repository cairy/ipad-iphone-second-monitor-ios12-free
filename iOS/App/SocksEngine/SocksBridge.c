#include "SocksBridge.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

/* Defined in sockssrv.c (renamed from `main` for the embedded build). */
extern int microsocks_main(int argc, char **argv);

static pthread_t g_thread;
static volatile int g_running = 0;

/* microsocks_main takes (argc, argv); pthread_create hands it a single void*,
   so we capture the args in static storage and call it from a thin shim. The
   argv strings live in static storage so they outlive socksbridge_start(). */
static int g_argc;
static char *g_argv[16];
static char g_listen_ip[16]; /* "127.0.0.1" */
static char g_port[16];      /* decimal port */
static char g_timeout[16];   /* "300" */

static void *socksbridge_main_thread(void *unused) {
    (void)unused;
    microsocks_main(g_argc, g_argv);
    return NULL;
}

int socksbridge_start(unsigned short device_port) {
    if (g_running) return -1;

    snprintf(g_listen_ip, sizeof g_listen_ip, "127.0.0.1");
    snprintf(g_port, sizeof g_port, "%u", device_port);
    snprintf(g_timeout, sizeof g_timeout, "300");

    /* Build argv: microsocks -q -i 127.0.0.1 -p <port> -t 300
       -q        quiet (no stderr logging into the system console)
       -i 127.0.0.1  bind loopback only; usbmuxd reaches the device at
                     localhost, so this is sufficient AND avoids exposing the
                     proxy on the iPad's Wi-Fi interface. If USB tunneling ever
                     fails to connect, switch this to "0.0.0.0".
       -t 300    idle timeout (seconds) so dead connections are reaped. */
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
    g_running = 1;
    return 0;
}

void socksbridge_stop(void) {
    /* See header: microsocks has no teardown; we only clear the flag. */
    g_running = 0;
}
