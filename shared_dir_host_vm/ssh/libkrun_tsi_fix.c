/*
 * libkrun_tsi_fix.c - Workaround for libkrunfw AF_TSI (tsi_hijack) port=0 bug
 *
 * Root Cause:
 *   In libkrunfw's net/tsi/af_tsi.c, when a guest process calls bind() on an
 *   AF_INET/AF_INET6 socket with sin_port == 0 (such as VS Code's code-server
 *   with --port=0):
 *     1. tsi_bind() binds the internal guest socket (isock) to port 0, which
 *        causes the guest kernel to allocate an ephemeral port (e.g. 39707).
 *     2. However, tsi_bind() copies the caller's original sockaddr (which still
 *        has sin_port == 0!) into tsi->addr.
 *     3. When tsi_listen() is subsequently called, it sends TSI_LISTEN with
 *        sin_port == 0 over virtio-vsock to libkrun on the Host PC. The Host PC
 *        binds a different random port and returns 0, causing tsi_listen() to
 *        skip calling isock->ops->listen().
 *     4. getsockname() returns isock's port (39707), which is not listening on
 *        either the Host PC or the Guest VM, causing sshd port forwarding to
 *        fail with ECONNREFUSED.
 *
 * Fix:
 *   Intercept glibc bind() for SOCK_STREAM AF_INET/AF_INET6 sockets when
 *   sin_port == 0, and substitute an explicit non-zero port from 20000..32000
 *   (outside the 32768..60999 client ephemeral port range), retrying on
 *   EADDRINUSE. With a non-zero port, tsi_bind() records the exact port in
 *   tsi->addr and tsi_listen() exposes that exact port consistently.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define PORT_RANGE_MIN 20000
#define PORT_RANGE_MAX 32000
#define PORT_RANGE_LEN (PORT_RANGE_MAX - PORT_RANGE_MIN)
#define MAX_BIND_RETRIES 128

typedef int (*bind_fn_t)(int, const struct sockaddr *, socklen_t);

static uint32_t g_port_counter = 0;

static uint16_t next_candidate_port(uint32_t attempt) {
    struct timespec ts = {0, 0};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint32_t c = __atomic_fetch_add(&g_port_counter, 1, __ATOMIC_RELAXED);
    uint32_t seed = (((uint32_t)getpid() * 2654435761U) ^
                     ((uint32_t)ts.tv_nsec >> 8) ^
                     (c * 1013904223U)) + attempt;
    return (uint16_t)(PORT_RANGE_MIN + (seed % PORT_RANGE_LEN));
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    static bind_fn_t real_bind = NULL;
    if (!real_bind) {
        real_bind = (bind_fn_t)dlsym(RTLD_NEXT, "bind");
        if (!real_bind) {
            errno = ENOSYS;
            return -1;
        }
    }

    if (!addr) {
        return real_bind(sockfd, addr, addrlen);
    }

    int saved_errno = errno;

    if (addr->sa_family == AF_INET && addrlen >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        if (sin->sin_port == 0) {
            int sock_type = 0;
            socklen_t optlen = sizeof(sock_type);
            if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sock_type, &optlen) == 0 &&
                sock_type == SOCK_STREAM) {
                int one = 1;
                (void)setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

                struct sockaddr_in sin_copy;
                memcpy(&sin_copy, sin, sizeof(sin_copy));

                for (uint32_t i = 0; i < MAX_BIND_RETRIES; i++) {
                    uint16_t port = next_candidate_port(i);
                    sin_copy.sin_port = htons(port);
                    errno = saved_errno;
                    int rc = real_bind(sockfd, (const struct sockaddr *)&sin_copy, sizeof(sin_copy));
                    if (rc == 0) {
                        return 0;
                    }
                    if (errno != EADDRINUSE && errno != EACCES) {
                        break;
                    }
                }
            }
        }
    } else if (addr->sa_family == AF_INET6 && addrlen >= (socklen_t)sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        if (sin6->sin6_port == 0) {
            int sock_type = 0;
            socklen_t optlen = sizeof(sock_type);
            if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sock_type, &optlen) == 0 &&
                sock_type == SOCK_STREAM) {
                int one = 1;
                (void)setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

                struct sockaddr_in6 sin6_copy;
                memcpy(&sin6_copy, sin6, sizeof(sin6_copy));

                for (uint32_t i = 0; i < MAX_BIND_RETRIES; i++) {
                    uint16_t port = next_candidate_port(i);
                    sin6_copy.sin6_port = htons(port);
                    errno = saved_errno;
                    int rc = real_bind(sockfd, (const struct sockaddr *)&sin6_copy, sizeof(sin6_copy));
                    if (rc == 0) {
                        return 0;
                    }
                    if (errno != EADDRINUSE && errno != EACCES) {
                        break;
                    }
                }
            }
        }
    }

    errno = saved_errno;
    return real_bind(sockfd, addr, addrlen);
}
