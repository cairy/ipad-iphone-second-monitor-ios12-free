#include "server.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <sys/time.h>

/* Per-socket send/receive buffer we ask the kernel for.
   The path is browser -> Mac bridge -> usbmuxd -> USB -> microsocks -> target,
   i.e. every byte crosses a USB tunnel whose round-trip is far worse than
   plain loopback. Buffer * bandwidth-delay-product: at ~30 MB/s and a few ms
   of tunnelling latency the pipe needs roughly 100 KB in flight before it
   stops going idle. The kernel clamps this to its own maximum, so asking for
   a generous value is safe — a too-small buffer is not. */
#ifndef SOCKS_SOCK_BUFSIZE
#define SOCKS_SOCK_BUFSIZE (128 * 1024)
#endif

void tune_socket(int fd) {
	int yes = 1;
	/* The single biggest latency win on this codebase. Nagle buffers small
	   writes until the previous ACK arrives; the peer's delayed-ACK timer
	   then waits its own ~40 ms before sending one. Chained over a USB
	   tunnel that combination routinely adds 40-200 ms to every request
	   that doesn't fill a full segment — HTTP headers, TLS handshakes,
	   keep-alive pings. Every socket in the chain needs this. */
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);

	int bufsize = SOCKS_SOCK_BUFSIZE;
	setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof bufsize);
	setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof bufsize);
}

void set_socket_timeout(int fd, int seconds) {
	struct timeval tv;
	tv.tv_sec = seconds;
	tv.tv_usec = 0;
	/* Only meaningful while the socket is still blocking. copyloop() flips
	   both ends to non-blocking and then relies on poll() for its timing,
	   so this guards the handshake phase only. */
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

void set_socket_nonblocking(int fd) {
	int fl = fcntl(fd, F_GETFL, 0);
	if(fl != -1) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

int resolve(const char *host, unsigned short port, struct addrinfo** addr) {
	struct addrinfo hints = {
		.ai_family = AF_UNSPEC,
		.ai_socktype = SOCK_STREAM,
		.ai_flags = AI_PASSIVE,
	};
	char port_buf[8];
	snprintf(port_buf, sizeof port_buf, "%u", port);
	return getaddrinfo(host, port_buf, &hints, addr);
}

int resolve_sa(const char *host, unsigned short port, union sockaddr_union *res) {
	struct addrinfo *ainfo = 0;
	int ret;
	SOCKADDR_UNION_AF(res) = AF_UNSPEC;
	if((ret = resolve(host, port, &ainfo))) return ret;
	memcpy(res, ainfo->ai_addr, ainfo->ai_addrlen);
	freeaddrinfo(ainfo);
	return 0;
}

int bindtoip(int fd, union sockaddr_union *bindaddr) {
	socklen_t sz = SOCKADDR_UNION_LENGTH(bindaddr);
	if(sz)
		return bind(fd, (struct sockaddr*) bindaddr, sz);
	return 0;
}

int server_waitclient(struct server *server, struct client* client) {
	socklen_t clen = sizeof client->addr;
	return ((client->fd = accept(server->fd, (void*)&client->addr, &clen)) == -1)*-1;
}

int server_setup(struct server *server, const char* listenip, unsigned short port) {
	struct addrinfo *ainfo = 0;
	if(resolve(listenip, port, &ainfo)) return -1;
	struct addrinfo* p;
	int listenfd = -1;
	for(p = ainfo; p; p = p->ai_next) {
		if((listenfd = socket(p->ai_family, p->ai_socktype, p->ai_protocol)) < 0)
			continue;
		int yes = 1;
		setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(int));
		if(bind(listenfd, p->ai_addr, p->ai_addrlen) < 0) {
			close(listenfd);
			listenfd = -1;
			continue;
		}
		break;
	}
	freeaddrinfo(ainfo);
	if(listenfd < 0) return -2;
	if(listen(listenfd, SOMAXCONN) < 0) {
		close(listenfd);
		return -3;
	}
	server->fd = listenfd;
	return 0;
}
