#import "IOSVMSocketProxy.h"
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

// A one-shot loopback listener lets the kernel retain connect/EINPROGRESS/kqueue semantics.
// The application can send TLS immediately; the relay waits for the remote proxy handshake
// before forwarding any application bytes. No replacement fd or blocking connect is used.
static NSString *proxyKind;
static NSArray<NSData *> *proxyAddresses;
static void (^reportEvent)(NSString *, NSString *, int);
static pthread_mutex_t relayLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned relayCount;
static NSUInteger openedTunnels, failedTunnels;
static int lastProxyError;
static const unsigned relayLimit = 128;
typedef struct Relay {
    int listener;
    struct sockaddr_storage target, local;
    socklen_t targetLength, localLength;
    struct Relay *next;
} Relay;
static Relay *relays;

static int64_t millis(void) {
    struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static BOOL waitFor(int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t left = deadline - millis();
        if (left <= 0) { errno = ETIMEDOUT; return NO; }
        struct pollfd p = {fd, events, 0};
        int result = poll(&p, 1, (int)MIN(left, INT_MAX));
        if (result < 0 && errno == EINTR) continue;
        if (result == 0) { errno = ETIMEDOUT; return NO; }
        if (result < 0) return NO;
        if (p.revents & POLLNVAL) { errno = EBADF; return NO; }
        return YES; // read/write or SO_ERROR reports HUP/ERR precisely.
    }
}
static void prepareFD(int fd) {
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
}
static BOOL transfer(int fd, void *bytes, size_t count, BOOL writing, int64_t deadline) {
    uint8_t *p = bytes;
    while (count) {
        ssize_t n = writing ? send(fd, p, count, 0) : recv(fd, p, count, 0);
        if (n > 0) { p += n; count -= n; continue; }
        if (n == 0) { errno = ECONNRESET; return NO; }
        if (errno == EINTR) continue;
        if ((errno == EAGAIN || errno == EWOULDBLOCK) && waitFor(fd, writing ? POLLOUT : POLLIN, deadline)) continue;
        return NO;
    }
    return YES;
}
static BOOL endpoint(const struct sockaddr *a, socklen_t length, char *host, unsigned *port) {
    if (a && a->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *v = (const void *)a;
        *port = ntohs(v->sin_port); return inet_ntop(AF_INET, &v->sin_addr, host, INET6_ADDRSTRLEN) != NULL;
    }
    if (a && a->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *v = (const void *)a;
        *port = ntohs(v->sin6_port); return inet_ntop(AF_INET6, &v->sin6_addr, host, INET6_ADDRSTRLEN) != NULL;
    }
    return NO;
}
static BOOL sameEndpoint(const struct sockaddr *a, socklen_t al, const struct sockaddr *b, socklen_t bl) {
    char ah[INET6_ADDRSTRLEN], bh[INET6_ADDRSTRLEN]; unsigned ap, bp;
    return endpoint(a, al, ah, &ap) && endpoint(b, bl, bh, &bp) && ap == bp && !strcmp(ah, bh);
}
static BOOL localDestination(const struct sockaddr *a, socklen_t n) {
    if (!a || n < 2) return NO;
    if (a->sa_family == AF_INET && n >= sizeof(struct sockaddr_in))
        return (ntohl(((const struct sockaddr_in *)a)->sin_addr.s_addr) >> 24) == 127;
    if (a->sa_family == AF_INET6 && n >= sizeof(struct sockaddr_in6)) {
        const struct in6_addr *ip = &((const struct sockaddr_in6 *)a)->sin6_addr;
        return IN6_IS_ADDR_LOOPBACK(ip) || (IN6_IS_ADDR_V4MAPPED(ip) && ip->s6_addr[12] == 127);
    }
    return NO;
}
static NSString *targetName(Relay *relay) {
    char host[INET6_ADDRSTRLEN]; unsigned port;
    if (!endpoint((void *)&relay->target, relay->targetLength, host, &port)) return @"";
    return [NSString stringWithFormat:relay->target.ss_family == AF_INET6 ? @"[%s]:%u" : @"%s:%u", host, port];
}
static int openProxy(int (*connectFunction)(int, const struct sockaddr *, socklen_t), int64_t deadline) {
    int saved = ECONNREFUSED;
    for (NSData *address in proxyAddresses) {
        const struct sockaddr *a = address.bytes;
        int fd = socket(a->sa_family, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) { saved = errno; continue; }
        prepareFD(fd);
        int result = connectFunction(fd, a, (socklen_t)address.length);
        if (result == 0) return fd;
        if (errno == EINPROGRESS && waitFor(fd, POLLOUT, deadline)) {
            int error = 0; socklen_t size = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && !error) return fd;
            if (error) errno = error;
        }
        saved = errno; close(fd);
    }
    errno = saved; return -1;
}
static BOOL handshake(int fd, Relay *relay, int64_t deadline) {
    if ([proxyKind isEqualToString:@"http"]) {
        NSString *target = targetName(relay);
        NSData *request = [[NSString stringWithFormat:@"CONNECT %@ HTTP/1.1\r\nHost: %@\r\n\r\n", target, target] dataUsingEncoding:NSASCIIStringEncoding];
        if (!transfer(fd, (void *)request.bytes, request.length, YES, deadline)) return NO;
        // Read exactly the headers; never consume the first tunneled TLS byte.
        uint8_t header[16384]; size_t n = 0;
        while (n < sizeof(header) - 1) {
            if (!transfer(fd, header + n, 1, NO, deadline)) return NO;
            n++;
            if (n >= 4 && !memcmp(header + n - 4, "\r\n\r\n", 4)) {
                header[n] = 0;
                if (n >= 12 && (!memcmp(header, "HTTP/1.1 ", 9) || !memcmp(header, "HTTP/1.0 ", 9)) &&
                    header[9] == '2' && header[10] >= '0' && header[10] <= '9' && header[11] >= '0' && header[11] <= '9') return YES;
                errno = EACCES; return NO;
            }
        }
        errno = EMSGSIZE; return NO;
    }
    uint8_t greeting[] = {5, 1, 0}, reply[4];
    if (!transfer(fd, greeting, sizeof(greeting), YES, deadline) || !transfer(fd, reply, 2, NO, deadline)) return NO;
    if (reply[0] != 5 || reply[1] != 0) { errno = EACCES; return NO; }
    uint8_t request[22] = {5, 1, 0}; size_t size;
    if (relay->target.ss_family == AF_INET) {
        const struct sockaddr_in *v = (void *)&relay->target;
        request[3] = 1; memcpy(request + 4, &v->sin_addr, 4); memcpy(request + 8, &v->sin_port, 2); size = 10;
    } else {
        const struct sockaddr_in6 *v = (void *)&relay->target;
        request[3] = 4; memcpy(request + 4, &v->sin6_addr, 16); memcpy(request + 20, &v->sin6_port, 2); size = 22;
    }
    if (!transfer(fd, request, size, YES, deadline) || !transfer(fd, reply, 4, NO, deadline)) return NO;
    if (reply[0] != 5 || reply[1] != 0 || reply[2] != 0) { errno = ECONNREFUSED; return NO; }
    size_t rest;
    if (reply[3] == 1) rest = 6;
    else if (reply[3] == 4) rest = 18;
    else if (reply[3] == 3) {
        if (!transfer(fd, reply, 1, NO, deadline)) return NO;
        rest = reply[0] + 2;
    } else { errno = EPROTO; return NO; }
    uint8_t tail[257]; return transfer(fd, tail, rest, NO, deadline);
}

typedef struct { uint8_t bytes[32768]; size_t begin, end; BOOL eof, shutdown; } Buffer;
static int pump(int a, int b) {
    Buffer ab = {0}, ba = {0};
    for (;;) {
        if (ab.eof && ab.begin == ab.end && !ab.shutdown) { shutdown(b, SHUT_WR); ab.shutdown = YES; }
        if (ba.eof && ba.begin == ba.end && !ba.shutdown) { shutdown(a, SHUT_WR); ba.shutdown = YES; }
        if (ab.shutdown && ba.shutdown) return 0;
        struct pollfd fds[2] = {{a, 0, 0}, {b, 0, 0}};
        if (!ab.eof && ab.end < sizeof(ab.bytes)) fds[0].events |= POLLIN;
        if (ba.begin < ba.end) fds[0].events |= POLLOUT;
        if (!ba.eof && ba.end < sizeof(ba.bytes)) fds[1].events |= POLLIN;
        if (ab.begin < ab.end) fds[1].events |= POLLOUT;
        // Exclude a half-closed fd when no operation is pending, avoiding persistent HUP spin.
        if (!fds[0].events) fds[0].fd = -1;
        if (!fds[1].events) fds[1].fd = -1;
        int result = poll(fds, 2, -1);
        if (result < 0) { if (errno == EINTR) continue; return errno; }
        for (int direction = 0; direction < 2; direction++) {
            Buffer *buf = direction == 0 ? &ab : &ba;
            int source = direction == 0 ? a : b, destination = direction == 0 ? b : a;
            short sr = fds[direction].revents, dr = fds[1-direction].revents;
            if (!buf->eof && buf->end < sizeof(buf->bytes) && (sr & (POLLIN | POLLHUP | POLLERR))) {
                ssize_t n = recv(source, buf->bytes + buf->end, sizeof(buf->bytes) - buf->end, 0);
                if (n > 0) buf->end += n;
                else if (n == 0) buf->eof = YES;
                else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return errno;
            }
            if (buf->begin < buf->end && (dr & (POLLOUT | POLLHUP | POLLERR))) {
                ssize_t n = send(destination, buf->bytes + buf->begin, buf->end - buf->begin, 0);
                if (n > 0) buf->begin += n;
                else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) return errno;
            }
            if (buf->begin == buf->end) buf->begin = buf->end = 0;
        }
    }
}
// Worker uses a fixed original connect pointer, never a rebound guest import.
typedef struct { Relay *relay; int (*connectFunction)(int, const struct sockaddr *, socklen_t); } Worker;
static void *runRelay(void *opaque) { @autoreleasepool {
    Worker worker = *(Worker *)opaque; free(opaque); Relay *relay = worker.relay;
    int accepted = -1, upstream = -1, failure = 0;
    int64_t deadline = millis() + 10000;
    while (waitFor(relay->listener, POLLIN, deadline)) {
        struct sockaddr_storage peer; socklen_t peerLength = sizeof(peer);
        accepted = accept(relay->listener, (void *)&peer, &peerLength);
        if (accepted < 0) { if (errno == EINTR || errno == EAGAIN) continue; break; }
        // Another local process must not claim this one-shot tunnel.
        if (sameEndpoint((void *)&peer, peerLength, (void *)&relay->local, relay->localLength)) break;
        close(accepted); accepted = -1;
    }
    if (accepted < 0) failure = errno;
    close(relay->listener);
    if (accepted >= 0) {
        prepareFD(accepted);
        upstream = openProxy(worker.connectFunction, deadline);
        if (upstream < 0 || !handshake(upstream, relay, deadline)) failure = errno;
        else {
            pthread_mutex_lock(&relayLock); openedTunnels++; pthread_mutex_unlock(&relayLock);
            if (reportEvent) reportEvent(@"tunnel", targetName(relay), 0);
            failure = pump(accepted, upstream);
        }
    }
    if (failure) {
        pthread_mutex_lock(&relayLock); failedTunnels++; lastProxyError = failure; pthread_mutex_unlock(&relayLock);
        if (reportEvent) reportEvent(@"proxyError", targetName(relay), failure);
    }
    if (upstream >= 0) close(upstream);
    if (accepted >= 0) close(accepted);
    pthread_mutex_lock(&relayLock);
    Relay **p = &relays; while (*p && *p != relay) p = &(*p)->next;
    if (*p) *p = relay->next;
    relayCount--; pthread_mutex_unlock(&relayLock); free(relay);
    return NULL;
} }

BOOL IOSVMSocketProxyConfigure(NSString *type, NSString *host, uint16_t port,
                              void (^event)(NSString *, NSString *, int), NSError **error) {
    if (![@[@"http", @"socks5"] containsObject:type]) { errno = EINVAL; return NO; }
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP;
    int result = getaddrinfo(host.UTF8String, [NSString stringWithFormat:@"%u", port].UTF8String, &hints, &addresses);
    if (result) {
        if (error) *error = [NSError errorWithDomain:@"IOSVMSocketProxy" code:result userInfo:@{NSLocalizedDescriptionKey:@"无法解析代理服务器地址。"}];
        return NO;
    }
    NSMutableArray *values = [NSMutableArray new];
    for (struct addrinfo *a = addresses; a; a = a->ai_next)
        if (a->ai_addrlen <= sizeof(struct sockaddr_storage)) [values addObject:[NSData dataWithBytes:a->ai_addr length:a->ai_addrlen]];
    freeaddrinfo(addresses);
    if (!values.count) return NO;
    proxyKind = type.copy; proxyAddresses = values.copy; reportEvent = [event copy]; return YES;
}
BOOL IOSVMSocketProxyRejectDatagram(int fd, const struct sockaddr *address, socklen_t length) {
    if (!proxyAddresses || !address || length < sizeof(struct sockaddr) || localDestination(address, length)) return NO;
    if (address->sa_family != AF_INET && address->sa_family != AF_INET6) return NO;
    int type; socklen_t size = sizeof(type);
    return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) == 0 && type == SOCK_DGRAM;
}
int IOSVMSocketProxyConnect(int fd, const struct sockaddr *address, socklen_t length,
                           int (*connectFunction)(int, const struct sockaddr *, socklen_t)) {
    if (!proxyAddresses || !address || length < sizeof(struct sockaddr) || localDestination(address, length) ||
        (address->sa_family != AF_INET && address->sa_family != AF_INET6)) return connectFunction(fd, address, length);
    char host[INET6_ADDRSTRLEN]; unsigned port;
    if (!endpoint(address, length, host, &port)) { errno = EINVAL; return -1; }
    int type; socklen_t size = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size)) return -1;
    if (type != SOCK_STREAM) { errno = EPROTONOSUPPORT; return -1; }
    // Avoid a second proxy hop when an application already connects to this proxy.
    for (NSData *proxy in proxyAddresses)
        if (sameEndpoint(address, length, proxy.bytes, (socklen_t)proxy.length)) return connectFunction(fd, address, length);
    struct sockaddr_storage peer; socklen_t peerLength = sizeof(peer);
    if (getpeername(fd, (void *)&peer, &peerLength) == 0) return connectFunction(fd, address, length);
    pthread_mutex_lock(&relayLock);
    if (relayCount >= relayLimit) { pthread_mutex_unlock(&relayLock); errno = EMFILE; return -1; }
    relayCount++; pthread_mutex_unlock(&relayLock);
    Relay *relay = calloc(1, sizeof(*relay));
    if (!relay) { pthread_mutex_lock(&relayLock); relayCount--; pthread_mutex_unlock(&relayLock); errno = ENOMEM; return -1; }
    relay->listener = -1;
    int failure = 0, result = -1, connectError = 0;
    socklen_t targetLength = address->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    memcpy(&relay->target, address, targetLength); relay->targetLength = targetLength;
    relay->listener = socket(address->sa_family, SOCK_STREAM, IPPROTO_TCP);
    if (relay->listener < 0) { failure = errno; goto fail; }
    prepareFD(relay->listener);
    struct sockaddr_storage loopback = {0}; socklen_t loopbackLength = targetLength;
    if (address->sa_family == AF_INET) {
        struct sockaddr_in *v = (void *)&loopback; v->sin_family = AF_INET; v->sin_len = sizeof(*v); v->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    } else {
        struct sockaddr_in6 *v = (void *)&loopback; v->sin6_family = AF_INET6; v->sin6_len = sizeof(*v); v->sin6_addr = in6addr_loopback;
    }
    if (bind(relay->listener, (void *)&loopback, loopbackLength) || listen(relay->listener, 1) ||
        getsockname(relay->listener, (void *)&loopback, &loopbackLength)) { failure = errno; goto fail; }
    result = connectFunction(fd, (void *)&loopback, loopbackLength); connectError = errno;
    if (result < 0 && connectError != EINPROGRESS) { failure = connectError; goto fail; }
    relay->localLength = sizeof(relay->local);
    if (getsockname(fd, (void *)&relay->local, &relay->localLength)) { failure = errno; goto connectedFail; }
    Worker *worker = malloc(sizeof(*worker));
    if (!worker) { failure = ENOMEM; goto connectedFail; }
    worker->relay = relay; worker->connectFunction = connectFunction;
    pthread_mutex_lock(&relayLock); relay->next = relays; relays = relay; pthread_mutex_unlock(&relayLock);
    pthread_t thread; pthread_attr_t attributes;
    pthread_attr_init(&attributes); pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attributes, 256 * 1024);
    failure = pthread_create(&thread, &attributes, runRelay, worker);
    pthread_attr_destroy(&attributes);
    if (failure) {
        free(worker); pthread_mutex_lock(&relayLock);
        Relay **p = &relays; while (*p && *p != relay) p = &(*p)->next;
        if (*p) *p = relay->next;
        pthread_mutex_unlock(&relayLock); goto connectedFail;
    }
    errno = connectError; return result;
connectedFail:
    shutdown(fd, SHUT_RDWR);
fail:
    if (relay->listener >= 0) close(relay->listener);
    free(relay); pthread_mutex_lock(&relayLock); relayCount--; pthread_mutex_unlock(&relayLock);
    errno = failure; return -1;
}
int IOSVMSocketProxyGetPeerName(int fd, struct sockaddr *address, socklen_t *length) {
    if (!proxyAddresses || !address || !length) return getpeername(fd, address, length);
    socklen_t capacity = *length;
    int result = getpeername(fd, address, length);
    if (result || !localDestination(address, MIN(capacity, *length))) return result;
    struct sockaddr_storage local; socklen_t localLength = sizeof(local);
    if (getsockname(fd, (void *)&local, &localLength)) return result;
    pthread_mutex_lock(&relayLock);
    for (Relay *relay = relays; relay; relay = relay->next) {
        if (sameEndpoint((void *)&local, localLength, (void *)&relay->local, relay->localLength)) {
            memcpy(address, &relay->target, MIN(capacity, relay->targetLength)); *length = relay->targetLength; break;
        }
    }
    pthread_mutex_unlock(&relayLock); return result;
}

NSDictionary *IOSVMSocketProxyStatus(void) {
    pthread_mutex_lock(&relayLock);
    NSDictionary *result = @{@"active":@(relayCount), @"opened":@(openedTunnels),
                             @"failed":@(failedTunnels), @"lastError":@(lastProxyError),
                             @"configured":@(proxyAddresses != nil)};
    pthread_mutex_unlock(&relayLock);
    return result;
}
