/*
   MicroSocks - multithreaded, small, efficient SOCKS5 server.

   Copyright (C) 2017 rofl0r.

   This is the successor of "rocksocks5", and it was written with
   different goals in mind:

   - prefer usage of standard libc functions over homegrown ones
   - no artificial limits
   - do not aim for minimal binary size, but for minimal source code size,
     and maximal readability, reusability, and extensibility.

   as a result of that, ipv4, dns, and ipv6 is supported out of the box
   and can use the same code, while rocksocks5 has several compile time
   defines to bring down the size of the resulting binary to extreme values
   like 10 KB static linked when only ipv4 support is enabled.

   still, if optimized for size, *this* program when static linked against musl
   libc is not even 50 KB. that's easily usable even on the cheapest routers.

*/

#define _GNU_SOURCE
#include <unistd.h>
#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <poll.h>
#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include "server.h"
#include "sblist.h"

/* timeout in microseconds on resource exhaustion to prevent excessive
   cpu usage. */
#ifndef FAILURE_TIMEOUT
#define FAILURE_TIMEOUT 64
#endif

/* Embedded build (LegacyPadDisplay): hard cap on concurrent SOCKS sessions.
   microsocks upstream has no limit; on a 2 GB device a runaway client could
   otherwise exhaust memory. Raised from 48 to 64: a single browser tab
   routinely holds a dozen keep-alive sockets, and the old cap was being hit
   during ordinary browsing, at which point every new connection was refused. */
#ifndef MAX_CLIENTS
#define MAX_CLIENTS 64
#endif

/* How long a client may sit in the SOCKS handshake before we drop it.
   Upstream has NO timeout here: recv() blocks forever, so a client that
   connects and then stays silent (crashed app, browser preconnect, port
   scanner, anything that half-opens) pins a slot until the idle timeout
   fires. Enough of those and MAX_CLIENTS is permanently exhausted and the
   proxy looks dead while still accepting TCP. 15 s is far above any real
   handshake but turns a 5-minute leak into a 15-second one. */
#ifndef HANDSHAKE_TIMEOUT
#define HANDSHAKE_TIMEOUT 15
#endif

/* When the gate is full we no longer accept-and-drop (which sent the browser
   an RST and made it retry-storm us). Instead we leave pending connections in
   the kernel backlog and poll for a free slot. 2 ms is a compromise between
   wakeup latency and CPU burn — the old code spun at 64 us, i.e. ~15k
   syscalls/s doing nothing. */
#ifndef GATE_BACKOFF_US
#define GATE_BACKOFF_US 2000
#endif

/* How often the accept loop wakes up to reap finished threads and to notice
   a stop request. Also bounds worst-case shutdown latency. */
#ifndef ACCEPT_POLL_MS
#define ACCEPT_POLL_MS 200
#endif

/* Per-direction buffer for the forwarding loop. Sized against the USB
   tunnel's bandwidth-delay product; see SOCKS_SOCK_BUFSIZE in server.c.
   Allocated on the heap, NOT the stack: THREAD_STACK_SIZE is only 64 KB. */
#ifndef PUMP_BUF_SIZE
#define PUMP_BUF_SIZE (64 * 1024)
#endif

#ifndef MAX
#define MAX(x, y) ((x) > (y) ? (x) : (y))
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#endif

#ifdef PTHREAD_STACK_MIN
#define THREAD_STACK_SIZE MAX(16*1024, PTHREAD_STACK_MIN)
#else
#define THREAD_STACK_SIZE 64*1024
#endif

#if defined(__APPLE__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 64*1024
#elif defined(__GLIBC__) || defined(__FreeBSD__) || defined(__sun__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 32*1024
#elif defined(__OpenBSD__) && defined(__clang__)
#undef THREAD_STACK_SIZE
#define THREAD_STACK_SIZE 32*1024
#endif

static int quiet, timeout;
static const char* auth_user;
static const char* auth_pass;
static sblist* auth_ips;
static pthread_rwlock_t auth_ips_lock = PTHREAD_RWLOCK_INITIALIZER;
static const struct server* server;
static union sockaddr_union bind_addr = {.v4.sin_family = AF_UNSPEC};

/* Lifecycle state (embedded build). Upstream microsocks is a stand-alone
   daemon: if server_setup() fails it prints and exits, and nothing ever stops
   it. Embedded in an app, nobody could tell whether the proxy was actually
   listening — the Swift wrapper set `started = true` unconditionally and every
   later health check was a no-op, so a dead proxy stayed "up" until the app
   was relaunched. These let the wrapper observe and restart it. */
static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_state = 0; /* enum microsocks_state */

enum microsocks_state {
	MSOCKS_IDLE = 0,    /* never started */
	MSOCKS_STARTING,    /* thread launched, listen socket not up yet */
	MSOCKS_RUNNING,     /* accept loop live */
	MSOCKS_STOPPED,     /* cleanly stopped via microsocks_request_stop() */
	MSOCKS_FAILED,      /* listen socket could not be created */
};

/* Ask the accept loop to exit. It unblocks within ACCEPT_POLL_MS. */
void microsocks_request_stop(void) {
	g_stop = 1;
}

/* 0=idle 1=starting 2=running 3=stopped 4=failed. The only state in which the
   proxy is actually serving traffic is MSOCKS_RUNNING. */
int microsocks_state(void) {
	return (int)g_state;
}

/* The predicate the Swift wrapper actually wants: is the accept loop live? */
int microsocks_is_running(void) {
	return g_state == MSOCKS_RUNNING;
}

enum socksstate {
	SS_1_CONNECTED,
	SS_2_NEED_AUTH, /* skipped if NO_AUTH method supported */
	SS_3_AUTHED,
};

enum authmethod {
	AM_NO_AUTH = 0,
	AM_GSSAPI = 1,
	AM_USERNAME = 2,
	AM_INVALID = 0xFF
};

enum errorcode {
	EC_SUCCESS = 0,
	EC_GENERAL_FAILURE = 1,
	EC_NOT_ALLOWED = 2,
	EC_NET_UNREACHABLE = 3,
	EC_HOST_UNREACHABLE = 4,
	EC_CONN_REFUSED = 5,
	EC_TTL_EXPIRED = 6,
	EC_COMMAND_NOT_SUPPORTED = 7,
	EC_ADDRESSTYPE_NOT_SUPPORTED = 8,
};

struct thread {
	pthread_t pt;
	struct client client;
	enum socksstate state;
	volatile int  done;
};

#ifndef CONFIG_LOG
#define CONFIG_LOG 1
#endif
#if CONFIG_LOG
/* we log to stderr because it's not using line buffering, i.e. malloc which would need
   locking when called from different threads. for the same reason we use dprintf,
   which writes directly to an fd. */
#define dolog(...) do { if(!quiet) dprintf(2, __VA_ARGS__); } while(0)
#else
static void dolog(const char* fmt, ...) { }
#endif

static struct addrinfo* addr_choose(struct addrinfo* list, union sockaddr_union* bindaddr) {
	int af = SOCKADDR_UNION_AF(bindaddr);
	if(af == AF_UNSPEC) return list;
	struct addrinfo* p;
	for(p=list; p; p=p->ai_next)
		if(p->ai_family == af) return p;
	return list;
}

static int connect_socks_target(unsigned char *buf, size_t n, struct client *client) {
	if(n < 5) return -EC_GENERAL_FAILURE;
	if(buf[0] != 5) return -EC_GENERAL_FAILURE;
	if(buf[1] != 1) return -EC_COMMAND_NOT_SUPPORTED; /* we support only CONNECT method */
	if(buf[2] != 0) return -EC_GENERAL_FAILURE; /* malformed packet */

	int af = AF_INET;
	size_t minlen = 4 + 4 + 2, l;
	char namebuf[256];
	struct addrinfo* remote;

	switch(buf[3]) {
		case 4: /* ipv6 */
			af = AF_INET6;
			minlen = 4 + 2 + 16;
			/* fall through */
		case 1: /* ipv4 */
			if(n < minlen) return -EC_GENERAL_FAILURE;
			if(namebuf != inet_ntop(af, buf+4, namebuf, sizeof namebuf))
				return -EC_GENERAL_FAILURE; /* malformed or too long addr */
			break;
		case 3: /* dns name */
			l = buf[4];
			minlen = 4 + 2 + l + 1;
			if(n < 4 + 2 + l + 1) return -EC_GENERAL_FAILURE;
			memcpy(namebuf, buf+4+1, l);
			namebuf[l] = 0;
			break;
		default:
			return -EC_ADDRESSTYPE_NOT_SUPPORTED;
	}
	unsigned short port;
	port = (buf[minlen-2] << 8) | buf[minlen-1];
	/* there's no suitable errorcode in rfc1928 for dns lookup failure */
	if(resolve(namebuf, port, &remote)) return -EC_GENERAL_FAILURE;
	struct addrinfo* raddr = addr_choose(remote, &bind_addr);
	int fd = socket(raddr->ai_family, SOCK_STREAM, 0);
	if(fd == -1) {
		eval_errno:
		if(fd != -1) close(fd);
		freeaddrinfo(remote);
		switch(errno) {
			case ETIMEDOUT:
				return -EC_TTL_EXPIRED;
			case EPROTOTYPE:
			case EPROTONOSUPPORT:
			case EAFNOSUPPORT:
				return -EC_ADDRESSTYPE_NOT_SUPPORTED;
			case ECONNREFUSED:
				return -EC_CONN_REFUSED;
			case ENETDOWN:
			case ENETUNREACH:
				return -EC_NET_UNREACHABLE;
			case EHOSTUNREACH:
				return -EC_HOST_UNREACHABLE;
			case EBADF:
			default:
			perror("socket/connect");
			return -EC_GENERAL_FAILURE;
		}
	}
	if(SOCKADDR_UNION_AF(&bind_addr) == raddr->ai_family &&
	   bindtoip(fd, &bind_addr) == -1)
		goto eval_errno;
	if(connect(fd, raddr->ai_addr, raddr->ai_addrlen) == -1)
		goto eval_errno;
	/* Same tuning as the client side — otherwise Nagle on the outbound
	   socket re-introduces exactly the latency we just removed. */
	tune_socket(fd);

	freeaddrinfo(remote);
	if(CONFIG_LOG) {
		char clientname[256];
		af = SOCKADDR_UNION_AF(&client->addr);
		void *ipdata = SOCKADDR_UNION_ADDRESS(&client->addr);
		inet_ntop(af, ipdata, clientname, sizeof clientname);
		dolog("client[%d] %s: connected to %s:%d\n", client->fd, clientname, namebuf, port);
	}
	return fd;
}

static int is_authed(union sockaddr_union *client, union sockaddr_union *authedip) {
	int af = SOCKADDR_UNION_AF(authedip);
	if(af == SOCKADDR_UNION_AF(client)) {
		size_t cmpbytes = af == AF_INET ? 4 : 16;
		void *cmp1 = SOCKADDR_UNION_ADDRESS(client);
		void *cmp2 = SOCKADDR_UNION_ADDRESS(authedip);
		if(!memcmp(cmp1, cmp2, cmpbytes)) return 1;
	}
	return 0;
}

static int is_in_authed_list(union sockaddr_union *caddr) {
	size_t i;
	for(i=0;i<sblist_getsize(auth_ips);i++)
		if(is_authed(caddr, sblist_get(auth_ips, i)))
			return 1;
	return 0;
}

static void add_auth_ip(union sockaddr_union *caddr) {
	sblist_add(auth_ips, caddr);
}

static enum authmethod check_auth_method(unsigned char *buf, size_t n, struct client*client) {
	if(buf[0] != 5) return AM_INVALID;
	size_t idx = 1;
	if(idx >= n ) return AM_INVALID;
	int n_methods = buf[idx];
	idx++;
	while(idx < n && n_methods > 0) {
		if(buf[idx] == AM_NO_AUTH) {
			if(!auth_user) return AM_NO_AUTH;
			else if(auth_ips) {
				int authed = 0;
				if(pthread_rwlock_rdlock(&auth_ips_lock) == 0) {
					authed = is_in_authed_list(&client->addr);
					pthread_rwlock_unlock(&auth_ips_lock);
				}
				if(authed) return AM_NO_AUTH;
			}
		} else if(buf[idx] == AM_USERNAME) {
			if(auth_user) return AM_USERNAME;
		}
		idx++;
		n_methods--;
	}
	return AM_INVALID;
}

static void send_auth_response(int fd, int version, enum authmethod meth) {
	unsigned char buf[2];
	buf[0] = version;
	buf[1] = meth;
	write(fd, buf, 2);
}

static void send_error(int fd, enum errorcode ec) {
	/* position 4 contains ATYP, the address type, which is the same as used in the connect
	   request. we're lazy and return always IPV4 address type in errors. */
	char buf[10] = { 5, ec, 0, 1 /*AT_IPV4*/, 0,0,0,0, 0,0 };
	write(fd, buf, 10);
}

/* One direction of a proxied connection: bytes read from `in` that are still
   waiting to be written to `out`. */
struct pumpdir {
	int in;
	int out;
	char *buf;
	size_t cap;
	size_t head; /* first byte still pending in buf */
	size_t len;  /* number of bytes pending */
	int in_eof;  /* nothing more will ever come from `in` */
	int flushed; /* we already half-closed `out` after draining */
};

static int pump_init(struct pumpdir *d, int in, int out, size_t cap) {
	d->in = in;
	d->out = out;
	d->cap = cap;
	d->head = d->len = 0;
	d->in_eof = d->flushed = 0;
	d->buf = malloc(cap);
	return d->buf ? 0 : -1;
}

static void pump_free(struct pumpdir *d) {
	free(d->buf);
	d->buf = 0;
}

static void pump_read(struct pumpdir *d) {
	if(d->in_eof) return;
	/* Slide pending bytes to the front so a single read can use the whole
	   tail of the buffer. Cheap: only runs when head is non-zero, and the
	   common case (stream fully drained) has len == 0 anyway. */
	if(d->head) {
		memmove(d->buf, d->buf + d->head, d->len);
		d->head = 0;
	}
	size_t space = d->cap - d->len;
	if(!space) return;
	/* read() returning 0 is the ONLY trustworthy end-of-stream signal.
	   POLLHUP is not: see the note in copyloop(). */
	ssize_t n = read(d->in, d->buf + d->len, space);
	if(n > 0) {
		d->len += (size_t)n;
		return;
	}
	if(n == 0) d->in_eof = 1; /* orderly EOF */
	else if(errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
		d->in_eof = 1;        /* hard error: stop reading this way */
}

/* Returns 0 if we made progress or merely blocked, -1 if `out` is broken.
   Partial writes are fine — whatever is left stays in the buffer and is
   retried on the next POLLOUT. */
static int pump_write(struct pumpdir *d) {
	while(d->len) {
		ssize_t m = write(d->out, d->buf + d->head, d->len);
		if(m > 0) {
			d->head += (size_t)m;
			d->len  -= (size_t)m;
			continue;
		}
		if(m < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
			return 0;
		return -1;
	}
	return 0;
}

/* Forward bytes between fd1 and fd2 until both directions are finished.

   Upstream microsocks used a strict read-then-write loop on one thread:
   whenever a write blocked, the *opposite* direction stalled with it. On a
   plain LAN link that is invisible; across a USB tunnel, where the peer
   socket fills up constantly, it means a slow download also freezes the
   request/ack stream going back, and interactive traffic (SSH, WebSockets,
   video control channels) crawls. This version keeps the two directions
   independent: each has its own buffer, both ends are non-blocking, and a
   full pipe only stops the direction feeding it. */
static void copyloop(int fd1, int fd2) {
	struct pumpdir d1, d2;
	if(pump_init(&d1, fd1, fd2, PUMP_BUF_SIZE)) return;
	if(pump_init(&d2, fd2, fd1, PUMP_BUF_SIZE)) {
		pump_free(&d1);
		return;
	}
	set_socket_nonblocking(fd1);
	set_socket_nonblocking(fd2);

	while(1) {
		/* Events are expressed per-fd: fd1 is the read end of d1 and the
		   write end of d2, and vice versa. */
		short w1 = 0, w2 = 0;
		if(!d1.in_eof && d1.len < d1.cap) w1 |= POLLIN;
		if(d2.len)                        w1 |= POLLOUT;
		if(!d2.in_eof && d2.len < d2.cap) w2 |= POLLIN;
		if(d1.len)                        w2 |= POLLOUT;

		/* Propagate EOF: once one side has nothing left to forward, half-close
		   the peer so it can finish its response and close in turn. Without
		   this, a client that sends a request and shuts down its write side
		   would hang until the idle timeout. */
		if(d1.in_eof && !d1.len && !d1.flushed) {
			shutdown(fd2, SHUT_WR);
			d1.flushed = 1;
		}
		if(d2.in_eof && !d2.len && !d2.flushed) {
			shutdown(fd1, SHUT_WR);
			d2.flushed = 1;
		}

		if(!w1 && !w2) break; /* both directions fully drained and closed */

		struct pollfd pfd[2] = {
			[0] = {.fd = fd1, .events = w1, .revents = 0},
			[1] = {.fd = fd2, .events = w2, .revents = 0},
		};
		int r = poll(pfd, 2, timeout ? timeout * 1000 : -1);
		if(r == 0) break; /* idle timeout */
		if(r < 0) {
			if(errno == EINTR || errno == EAGAIN) continue;
			break;
		}
		/* POLLERR/POLLNVAL mean the connection is broken; nothing can be
		   salvaged in either direction. */
		if(pfd[0].revents & (POLLERR | POLLNVAL)) { d1.in_eof = d2.in_eof = 1; }
		if(pfd[1].revents & (POLLERR | POLLNVAL)) { d1.in_eof = d2.in_eof = 1; }

		/* POLLHUP must NOT be treated as end-of-stream here, and this is the
		   one genuinely platform-specific trap in this loop. On Linux, POLLHUP
		   only appears once the socket is shut down in *both* directions, so
		   treating it as EOF is harmless. On Darwin — which is what this code
		   actually ships on — POLLHUP is reported as soon as the peer sends
		   FIN, *while received data is still sitting unread in the kernel
		   buffer*. Acting on it immediately truncates the transfer: a client
		   that sends a request and then half-closes loses everything the proxy
		   had not yet drained. Measured on this codebase: 200000 bytes in,
		   131072 forwarded, 68928 silently dropped.
		   So we keep reading while POLLHUP says the peer is done, and let
		   read() returning 0 be the thing that ends the stream. The
		   `!d->in_eof` guard stops us spinning once it has. */
		if(!d1.in_eof && (pfd[0].revents & (POLLIN | POLLHUP))) pump_read(&d1);
		if(pfd[1].revents & POLLOUT) if(pump_write(&d1) < 0) break;
		if(!d2.in_eof && (pfd[1].revents & (POLLIN | POLLHUP))) pump_read(&d2);
		if(pfd[0].revents & POLLOUT) if(pump_write(&d2) < 0) break;
	}

	pump_free(&d1);
	pump_free(&d2);
}

static enum errorcode check_credentials(unsigned char* buf, size_t n) {
	if(n < 5) return EC_GENERAL_FAILURE;
	if(buf[0] != 1) return EC_GENERAL_FAILURE;
	unsigned ulen, plen;
	ulen=buf[1];
	if(n < 2 + ulen + 2) return EC_GENERAL_FAILURE;
	plen=buf[2+ulen];
	if(n < 2 + ulen + 1 + plen) return EC_GENERAL_FAILURE;
	char user[256], pass[256];
	memcpy(user, buf+2, ulen);
	memcpy(pass, buf+2+ulen+1, plen);
	user[ulen] = 0;
	pass[plen] = 0;
	if(!strcmp(user, auth_user) && !strcmp(pass, auth_pass)) return EC_SUCCESS;
	return EC_NOT_ALLOWED;
}

static int handshake(struct thread *t) {
	unsigned char buf[1024];
	ssize_t n;
	int ret;
	enum authmethod am;
	t->state = SS_1_CONNECTED;
	while((n = recv(t->client.fd, buf, sizeof buf, 0)) > 0) {
		switch(t->state) {
			case SS_1_CONNECTED:
				am = check_auth_method(buf, n, &t->client);
				if(am == AM_NO_AUTH) t->state = SS_3_AUTHED;
				else if (am == AM_USERNAME) t->state = SS_2_NEED_AUTH;
				send_auth_response(t->client.fd, 5, am);
				if(am == AM_INVALID) return -1;
				break;
			case SS_2_NEED_AUTH:
				ret = check_credentials(buf, n);
				send_auth_response(t->client.fd, 1, ret);
				if(ret != EC_SUCCESS)
					return -1;
				t->state = SS_3_AUTHED;
				if(auth_ips && !pthread_rwlock_wrlock(&auth_ips_lock)) {
					if(!is_in_authed_list(&t->client.addr))
						add_auth_ip(&t->client.addr);
					pthread_rwlock_unlock(&auth_ips_lock);
				}
				break;
			case SS_3_AUTHED:
				ret = connect_socks_target(buf, n, &t->client);
				if(ret < 0) {
					send_error(t->client.fd, ret*-1);
					return -1;
				}
				send_error(t->client.fd, EC_SUCCESS);
				return ret;
		}
	}
	return -1;
}

static void* clientthread(void *data) {
	struct thread *t = data;
	int remotefd = handshake(t);
	if(remotefd != -1) {
		copyloop(t->client.fd, remotefd);
		close(remotefd);
	}
	close(t->client.fd);
	t->done = 1;
	return 0;
}

static void collect(sblist *threads) {
	size_t i;
	for(i=0;i<sblist_getsize(threads);) {
		struct thread* thread = *((struct thread**)sblist_get(threads, i));
		if(thread->done) {
			pthread_join(thread->pt, 0);
			sblist_delete(threads, i);
			free(thread);
		} else
			i++;
	}
}

static int usage(void) {
	dprintf(2,
		"MicroSocks SOCKS5 Server\n"
		"------------------------\n"
		"usage: microsocks -1 -q -t timeout -i listenip -p port -u user -P pass -b bindaddr -w ips\n"
		"all arguments are optional.\n"
		"by default listenip is 0.0.0.0 and port 1080.\n\n"
		"-q disables logging.\n"
		"-b specifies which ip outgoing connections are bound to\n"
		"-t timeout is specified in seconds, default 0.\n"
		"   if timeout is set to 0, block until the OS signals activity.\n"
		"-w allows to specify a comma-separated whitelist of ip addresses,\n"
		"   that may use the proxy without user/pass authentication.\n"
		"   e.g. -w 127.0.0.1,192.168.1.1.1,::1 or just -w 10.0.0.1\n"
		"   to allow access ONLY to those ips, choose impossible to guess user/pw combo.\n"
		"-1 activates auth_once mode: once a specific ip address\n"
		"   authed successfully with user/pass, it is added to a whitelist\n"
		"   and may use the proxy without auth.\n"
		"   this is handy for programs like firefox that don't support\n"
		"   user/pass auth. for it to work you'd basically make one connection\n"
		"   with another program that supports it, and then you can use firefox too.\n"
	);
	return 1;
}

/* prevent username and password from showing up in top. */
static void zero_arg(char *s) {
	size_t i, l = strlen(s);
	for(i=0;i<l;i++) s[i] = 0;
}

/* Renamed from `main` for the embedded build: LegacyPadDisplay already has a
   `main` (generated by @UIApplicationMain), so the SOCKS server must live on
   its own thread launched from SocksBridge.c. This function never returns. */
int microsocks_main(int argc, char** argv) {
	int ch;
	const char *listenip = "0.0.0.0";
	char *p, *q;
	unsigned port = 1080;
	while((ch = getopt(argc, argv, ":1qb:t:i:p:u:P:w:")) != -1) {
		switch(ch) {
			case 'w': /* fall-through */
			case '1':
				if(!auth_ips)
					auth_ips = sblist_new(sizeof(union sockaddr_union), 8);
				if(ch == '1') break;
				p = optarg;
				while(1) {
					union sockaddr_union ca;
					if((q = strchr(p, ','))) *q = 0;
					if(resolve_sa(p, 0, &ca)) {
						dprintf(2, "error: failed to resolve %s\n", p);
						return 1;
					}
					add_auth_ip(&ca);
					if(q) *(q++) = ',', p = q;
					else break;
				}
				break;
			case 'q':
				quiet = 1;
				break;
			case 't':
				timeout = atoi(optarg);
				break;
			case 'b':
				resolve_sa(optarg, 0, &bind_addr);
				break;
			case 'u':
				auth_user = strdup(optarg);
				zero_arg(optarg);
				break;
			case 'P':
				auth_pass = strdup(optarg);
				zero_arg(optarg);
				break;
			case 'i':
				listenip = optarg;
				break;
			case 'p':
				port = atoi(optarg);
				break;
			case ':':
				dprintf(2, "error: option -%c requires an operand\n", optopt);
				/* fall through */
			case '?':
				return usage();
		}
	}
	if((auth_user && !auth_pass) || (!auth_user && auth_pass)) {
		dprintf(2, "error: user and pass must be used together\n");
		return 1;
	}
	if(auth_ips && !auth_pass) {
		dprintf(2, "error: -1/-w options must be used together with user/pass\n");
		return 1;
	}
	if(g_state == MSOCKS_RUNNING) return 1; /* already live */
	g_state = MSOCKS_STARTING;
	g_stop = 0; /* clear any stop left over from a previous run */

	signal(SIGPIPE, SIG_IGN);
	struct server s;
	sblist *threads = sblist_new(sizeof (struct thread*), 8);
	if(!threads) {
		dolog("OOM while allocating thread list\n");
		g_state = MSOCKS_FAILED;
		return 1;
	}
	if(server_setup(&s, listenip, port)) {
		perror("server_setup");
		sblist_free(threads);
		g_state = MSOCKS_FAILED;
		return 1;
	}
	server = &s;
	g_state = MSOCKS_RUNNING;

	while(!g_stop) {
		collect(threads);
		/* Concurrency gate (embedded build). Deliberately does NOT accept:
		   the old code accepted and immediately closed, which hands the
		   browser an RST. It treats that as a hard failure and retries at
		   once, so a momentarily full proxy turned into a retry storm that
		   kept it full. Leaving the connection in the kernel backlog means
		   the client just waits briefly and is served FIFO as slots free up.
		   collect() runs before the check, so finished threads are already
		   reaped and the count is honest. */
		if(sblist_getsize(threads) >= MAX_CLIENTS) {
			usleep(GATE_BACKOFF_US);
			continue;
		}

		/* Poll rather than blocking in accept(), so we can (a) reap finished
		   threads even when no new connection is arriving, and (b) notice a
		   stop request within ACCEPT_POLL_MS. Both were impossible with a
		   blocking accept. */
		struct pollfd apfd;
		apfd.fd = s.fd;
		apfd.events = POLLIN;
		apfd.revents = 0;
		int pr = poll(&apfd, 1, ACCEPT_POLL_MS);
		if(pr == 0) continue;
		if(pr < 0) {
			if(errno == EINTR || errno == EAGAIN) continue;
			usleep(FAILURE_TIMEOUT);
			continue;
		}
		if(!(apfd.revents & (POLLIN | POLLHUP))) continue;

		struct client c;
		struct thread *curr = malloc(sizeof (struct thread));
		if(!curr) goto oom;
		curr->done = 0;
		if(server_waitclient(&s, &c)) {
			if(errno == ECONNABORTED || errno == EAGAIN || errno == EWOULDBLOCK) {
				/* Client hung up during the handshake: routine on a busy
				   proxy, must not be logged or retried as a failure. */
				free(curr);
				continue;
			}
			dolog("failed to accept connection\n");
			free(curr);
			usleep(FAILURE_TIMEOUT);
			continue;
		}
		curr->client = c;
		/* Both applied before the handshake. TCP_NODELAY covers the whole
		   session; the recv timeout stops a client that connects and then
		   stays silent from pinning a slot (see HANDSHAKE_TIMEOUT). */
		tune_socket(c.fd);
		set_socket_timeout(c.fd, HANDSHAKE_TIMEOUT);
		if(!sblist_add(threads, &curr)) {
			close(curr->client.fd);
			free(curr);
			oom:
			dolog("rejecting connection due to OOM\n");
			usleep(FAILURE_TIMEOUT); /* prevent 100% CPU usage in OOM situation */
			continue;
		}
		pthread_attr_t *a = 0, attr;
		if(pthread_attr_init(&attr) == 0) {
			a = &attr;
			pthread_attr_setstacksize(a, THREAD_STACK_SIZE);
		}
		if(pthread_create(&curr->pt, a, clientthread, curr) != 0) {
			sblist_delete(threads, sblist_getsize(threads)-1);
			close(curr->client.fd);
			free(curr);
			dolog("pthread_create failed. OOM?\n");
			usleep(FAILURE_TIMEOUT);
		}
		if(a) pthread_attr_destroy(&attr);
	}

	/* Shutdown path (embedded build). Upstream has no teardown whatsoever,
	   which is why the Swift wrapper could never restart the proxy after iOS
	   reclaimed the listening socket during a long background. Nudge every
	   live connection so its poll() returns promptly, then join. */
	close(s.fd);
	size_t i;
	for(i=0;i<sblist_getsize(threads);i++) {
		struct thread* th = *((struct thread**)sblist_get(threads, i));
		shutdown(th->client.fd, SHUT_RDWR);
	}
	for(i=0;i<sblist_getsize(threads);i++) {
		struct thread* th = *((struct thread**)sblist_get(threads, i));
		pthread_join(th->pt, 0);
		free(th);
	}
	sblist_free(threads);
	server = 0;
	g_state = MSOCKS_STOPPED;
	return 0;
}
