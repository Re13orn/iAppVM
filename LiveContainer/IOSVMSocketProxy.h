#import <Foundation/Foundation.h>
#include <sys/socket.h>

/// Per-guest TCP relay. It preserves the application's fd and nonblocking flags.
/// TLS bytes are forwarded unchanged; this layer does not bypass certificate validation.
BOOL IOSVMSocketProxyConfigure(NSString *type, NSString *host, uint16_t port,
                              void (^event)(NSString *state, NSString *target, int code), NSError **error);
int IOSVMSocketProxyConnect(int fd, const struct sockaddr *address, socklen_t length,
                           int (*connectFunction)(int, const struct sockaddr *, socklen_t));
int IOSVMSocketProxyGetPeerName(int fd, struct sockaddr *address, socklen_t *length);
BOOL IOSVMSocketProxyRejectDatagram(int fd, const struct sockaddr *address, socklen_t length);

/// Volatile counters only: no request data, credentials or target addresses.
NSDictionary *IOSVMSocketProxyStatus(void);
