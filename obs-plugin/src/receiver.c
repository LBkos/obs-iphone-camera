#include "receiver.h"
#include "discovery.h"
#include "protocol.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define CLIENT_TIMEOUT_MS 5000
#define READ_CHUNK (256 * 1024)

struct obscam_receiver {
	struct obscam_receiver_callbacks cb;
	uint16_t port;
	char *service_name;

	pthread_t thread;
	int wake_pipe[2];
	int listen_fd;
	int client_fd;

	uint8_t *buf;
	size_t buf_len;
	size_t buf_cap;
	uint64_t last_rx_ms;
};

static void rlog(struct obscam_receiver *r, int level, const char *fmt, ...)
{
	if (!r->cb.log)
		return;
	char msg[512];
	va_list args;
	va_start(args, fmt);
	vsnprintf(msg, sizeof(msg), fmt, args);
	va_end(args);
	r->cb.log(r->cb.ctx, level, msg);
}

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static uint32_t read_u32_be(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t read_u64_be(const uint8_t *p)
{
	return ((uint64_t)read_u32_be(p) << 32) | (uint64_t)read_u32_be(p + 4);
}

static void set_cloexec(int fd)
{
	int flags = fcntl(fd, F_GETFD);
	if (flags >= 0)
		fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static int open_listen_socket(struct obscam_receiver *r)
{
	int one = 1;
	int zero = 0;

	/* Dual-stack IPv6 socket accepts IPv4 too; fall back to IPv4 only. */
	int fd = socket(AF_INET6, SOCK_STREAM, 0);
	if (fd >= 0) {
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));
		struct sockaddr_in6 addr6;
		memset(&addr6, 0, sizeof(addr6));
		addr6.sin6_family = AF_INET6;
		addr6.sin6_addr = in6addr_any;
		addr6.sin6_port = htons(r->port);
		if (bind(fd, (struct sockaddr *)&addr6, sizeof(addr6)) == 0 && listen(fd, 4) == 0) {
			set_cloexec(fd);
			return fd;
		}
		close(fd);
	}

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		rlog(r, 2, "socket() failed: %s", strerror(errno));
		return -1;
	}
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in addr4;
	memset(&addr4, 0, sizeof(addr4));
	addr4.sin_family = AF_INET;
	addr4.sin_addr.s_addr = htonl(INADDR_ANY);
	addr4.sin_port = htons(r->port);
	if (bind(fd, (struct sockaddr *)&addr4, sizeof(addr4)) != 0 || listen(fd, 4) != 0) {
		rlog(r, 2, "cannot listen on port %u: %s", r->port, strerror(errno));
		close(fd);
		return -1;
	}
	set_cloexec(fd);
	return fd;
}

static void drop_client(struct obscam_receiver *r, const char *reason)
{
	if (r->client_fd < 0)
		return;
	rlog(r, 0, "iPhone disconnected (%s)", reason);
	close(r->client_fd);
	r->client_fd = -1;
	r->buf_len = 0;
	if (r->cb.disconnected)
		r->cb.disconnected(r->cb.ctx);
}

static void accept_client(struct obscam_receiver *r)
{
	struct sockaddr_storage addr;
	socklen_t addr_len = sizeof(addr);
	int fd = accept(r->listen_fd, (struct sockaddr *)&addr, &addr_len);
	if (fd < 0) {
		rlog(r, 1, "accept() failed: %s", strerror(errno));
		return;
	}
	set_cloexec(fd);

	/* A new connection replaces a stale one (e.g. phone switched networks). */
	drop_client(r, "replaced by new connection");

	char peer[INET6_ADDRSTRLEN] = "?";
	if (addr.ss_family == AF_INET6) {
		struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&addr;
		if (IN6_IS_ADDR_V4MAPPED(&a6->sin6_addr))
			inet_ntop(AF_INET, &a6->sin6_addr.s6_addr[12], peer, sizeof(peer));
		else
			inet_ntop(AF_INET6, &a6->sin6_addr, peer, sizeof(peer));
	} else if (addr.ss_family == AF_INET) {
		inet_ntop(AF_INET, &((struct sockaddr_in *)&addr)->sin_addr, peer, sizeof(peer));
	}

	int rcvbuf = 4 * 1024 * 1024;
	setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

	r->client_fd = fd;
	r->buf_len = 0;
	r->last_rx_ms = now_ms();
	rlog(r, 0, "iPhone connected from %s", peer);
	if (r->cb.connected)
		r->cb.connected(r->cb.ctx, peer);
}

/* Returns false on a protocol error (caller drops the client). */
static bool handle_message(struct obscam_receiver *r, uint8_t type, const uint8_t *payload, size_t size)
{
	switch (type) {
	case OBSCAM_MSG_HELLO: {
		char name[128];
		size_t n = size < sizeof(name) - 1 ? size : sizeof(name) - 1;
		memcpy(name, payload, n);
		name[n] = '\0';
		rlog(r, 0, "device name: %s", name);
		if (r->cb.hello)
			r->cb.hello(r->cb.ctx, name);
		return true;
	}
	case OBSCAM_MSG_CONFIG:
		if (r->cb.config)
			r->cb.config(r->cb.ctx, payload, size);
		return true;
	case OBSCAM_MSG_FRAME:
		if (size < OBSCAM_FRAME_PREFIX_SIZE)
			return false;
		if (r->cb.frame)
			r->cb.frame(r->cb.ctx, read_u64_be(payload), (payload[8] & OBSCAM_FLAG_KEYFRAME) != 0,
				    payload + OBSCAM_FRAME_PREFIX_SIZE, size - OBSCAM_FRAME_PREFIX_SIZE);
		return true;
	case OBSCAM_MSG_PING:
		return true;
	default:
		/* Unknown messages are skipped for forward compatibility. */
		return true;
	}
}

static void read_client(struct obscam_receiver *r)
{
	if (r->buf_cap - r->buf_len < READ_CHUNK) {
		size_t new_cap = r->buf_cap ? r->buf_cap * 2 : 2 * READ_CHUNK;
		while (new_cap - r->buf_len < READ_CHUNK)
			new_cap *= 2;
		uint8_t *nb = realloc(r->buf, new_cap);
		if (!nb) {
			drop_client(r, "out of memory");
			return;
		}
		r->buf = nb;
		r->buf_cap = new_cap;
	}

	ssize_t n = recv(r->client_fd, r->buf + r->buf_len, r->buf_cap - r->buf_len, 0);
	if (n == 0) {
		drop_client(r, "closed by phone");
		return;
	}
	if (n < 0) {
		if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
			return;
		drop_client(r, strerror(errno));
		return;
	}
	r->buf_len += (size_t)n;
	r->last_rx_ms = now_ms();

	size_t off = 0;
	while (r->buf_len - off >= OBSCAM_HEADER_SIZE) {
		const uint8_t *hdr = r->buf + off;
		uint32_t len = read_u32_be(hdr + 1);
		if (len > OBSCAM_MAX_PAYLOAD) {
			rlog(r, 2, "message too large (%u bytes)", len);
			drop_client(r, "protocol error");
			return;
		}
		if (r->buf_len - off < OBSCAM_HEADER_SIZE + (size_t)len)
			break;
		if (!handle_message(r, hdr[0], hdr + OBSCAM_HEADER_SIZE, len)) {
			rlog(r, 2, "malformed message of type 0x%02x", hdr[0]);
			drop_client(r, "protocol error");
			return;
		}
		off += OBSCAM_HEADER_SIZE + (size_t)len;
	}
	if (off > 0) {
		memmove(r->buf, r->buf + off, r->buf_len - off);
		r->buf_len -= off;
	}
}

static void *receiver_thread(void *arg)
{
	struct obscam_receiver *r = arg;
	obscam_discovery_t *discovery = obscam_discovery_register(r->service_name, r->port);
	if (discovery)
		rlog(r, 0, "advertising %s via Bonjour on port %u", OBSCAM_SERVICE_TYPE, r->port);
	else
		rlog(r, 1, "Bonjour advertisement unavailable; enter this computer's IP in the app (port %u)",
		     r->port);

	for (;;) {
		struct pollfd fds[4];
		int nfds = 0;
		fds[nfds++] = (struct pollfd){.fd = r->wake_pipe[0], .events = POLLIN};
		int listen_idx = nfds;
		fds[nfds++] = (struct pollfd){.fd = r->listen_fd, .events = POLLIN};
		int client_idx = -1;
		if (r->client_fd >= 0) {
			client_idx = nfds;
			fds[nfds++] = (struct pollfd){.fd = r->client_fd, .events = POLLIN};
		}
		int dnssd_idx = -1;
		int dnssd_fd = obscam_discovery_fd(discovery);
		if (dnssd_fd >= 0) {
			dnssd_idx = nfds;
			fds[nfds++] = (struct pollfd){.fd = dnssd_fd, .events = POLLIN};
		}

		int rc = poll(fds, (nfds_t)nfds, 1000);
		if (rc < 0) {
			if (errno == EINTR)
				continue;
			rlog(r, 2, "poll() failed: %s", strerror(errno));
			break;
		}

		if (fds[0].revents)
			break; /* stop requested */
		if (fds[listen_idx].revents & POLLIN)
			accept_client(r);
		if (client_idx >= 0 && r->client_fd == fds[client_idx].fd &&
		    (fds[client_idx].revents & (POLLIN | POLLHUP | POLLERR)))
			read_client(r);
		if (dnssd_idx >= 0 && (fds[dnssd_idx].revents & POLLIN))
			obscam_discovery_process(discovery);

		if (r->client_fd >= 0 && now_ms() - r->last_rx_ms > CLIENT_TIMEOUT_MS)
			drop_client(r, "timeout");
	}

	drop_client(r, "source stopped");
	obscam_discovery_unregister(discovery);
	return NULL;
}

obscam_receiver_t *obscam_receiver_start(uint16_t port, const char *service_name,
					 const struct obscam_receiver_callbacks *callbacks)
{
	struct obscam_receiver *r = calloc(1, sizeof(*r));
	if (!r)
		return NULL;
	r->cb = *callbacks;
	r->port = port;
	r->service_name = service_name ? strdup(service_name) : NULL;
	r->client_fd = -1;
	r->wake_pipe[0] = r->wake_pipe[1] = -1;

	if (pipe(r->wake_pipe) != 0) {
		rlog(r, 2, "pipe() failed: %s", strerror(errno));
		goto fail;
	}
	set_cloexec(r->wake_pipe[0]);
	set_cloexec(r->wake_pipe[1]);

	r->listen_fd = open_listen_socket(r);
	if (r->listen_fd < 0)
		goto fail;

	if (pthread_create(&r->thread, NULL, receiver_thread, r) != 0) {
		rlog(r, 2, "pthread_create() failed");
		close(r->listen_fd);
		goto fail;
	}
	rlog(r, 0, "listening on TCP port %u", port);
	return r;

fail:
	if (r->wake_pipe[0] >= 0)
		close(r->wake_pipe[0]);
	if (r->wake_pipe[1] >= 0)
		close(r->wake_pipe[1]);
	free(r->service_name);
	free(r);
	return NULL;
}

void obscam_receiver_stop(obscam_receiver_t *r)
{
	if (!r)
		return;
	char c = 'x';
	ssize_t ignored = write(r->wake_pipe[1], &c, 1);
	(void)ignored;
	pthread_join(r->thread, NULL);

	close(r->listen_fd);
	close(r->wake_pipe[0]);
	close(r->wake_pipe[1]);
	free(r->buf);
	free(r->service_name);
	free(r);
}
