#import <Foundation/Foundation.h>
#import "../../LiveContainer/IOSVMSocketProxy.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/event.h>
#include <unistd.h>
#include <pthread.h>
static void check(BOOL ok, const char *message) { if (!ok) {fprintf(stderr,"FAIL: %s errno=%d\n",message,errno);exit(1);} }
static int newConnection(BOOL ipv6, BOOL nonblocking, BOOL local) {
    int fd=socket(ipv6?AF_INET6:AF_INET,SOCK_STREAM,IPPROTO_TCP);check(fd>=0,"socket");
    int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    if(nonblocking)fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);
    struct sockaddr_storage target={0};socklen_t length;
    if(ipv6){struct sockaddr_in6 *a=(void *)&target;a->sin6_len=sizeof(*a);a->sin6_family=AF_INET6;a->sin6_port=htons(19090);inet_pton(AF_INET6,"2001:db8::42",&a->sin6_addr);length=sizeof(*a);}
    else {struct sockaddr_in *a=(void *)&target;a->sin_len=sizeof(*a);a->sin_family=AF_INET;a->sin_port=htons(19090);inet_pton(AF_INET,local?"127.0.0.1":"198.51.100.42",&a->sin_addr);length=sizeof(*a);}
    int result=IOSVMSocketProxyConnect(fd,(void *)&target,length,connect);
    if(nonblocking){check(result==0||(result==-1&&errno==EINPROGRESS),"nonblocking connect result");
        int kq=kqueue();struct kevent change,event;EV_SET(&change,fd,EVFILT_WRITE,EV_ADD|EV_ONESHOT,0,0,NULL);struct timespec deadline={3,0};
        check(kevent(kq,&change,1,&event,1,&deadline)==1,"kqueue connect readiness");close(kq);
        int error=0;socklen_t size=sizeof(error);check(getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size)==0&&!error,"SO_ERROR");
    } else check(result==0,"blocking connect");
    check(!!(fcntl(fd,F_GETFL)&O_NONBLOCK)==nonblocking,"fd flags changed");
    struct sockaddr_storage peer={0};socklen_t size=sizeof(peer);
    check(IOSVMSocketProxyGetPeerName(fd,(void *)&peer,&size)==0,"getpeername");
    check(size==length&&!memcmp(&peer,&target,length),"original destination not preserved");
    return fd;
}
static void roundTrip(BOOL ipv6, BOOL nonblocking, BOOL local) {
    int fd=newConnection(ipv6,nonblocking,local);
    // Always use nonblocking IO in this harness; connect itself was tested in both modes.
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);
    const size_t count=256*1024;uint8_t *sent=malloc(count),*received=malloc(count);for(size_t i=0;i<count;i++)sent[i]=(i*17)%251;
    size_t out=0,in=0;BOOL ended=NO;
    while(in<count){struct pollfd p={fd,(short)(POLLIN|(out<count?POLLOUT:0)),0};check(poll(&p,1,15000)>0,"echo readiness timeout");
        if(out<count&&(p.revents&POLLOUT)){ssize_t n=send(fd,sent+out,MIN(count-out,4093),0);if(n>0)out+=n;else check(errno==EAGAIN||errno==EINTR,"echo send");}
        if(out==count&&!ended){check(shutdown(fd,SHUT_WR)==0,"half-close");ended=YES;}
        if(p.revents&(POLLIN|POLLHUP)){ssize_t n=recv(fd,received+in,count-in,0);if(n>0)in+=n;else check(n<0&&(errno==EAGAIN||errno==EINTR),"echo truncated");}
    }
    check(!memcmp(sent,received,count),"payload corruption");
    struct pollfd p={fd,POLLIN,0};check(poll(&p,1,3000)>0,"half-close EOF timeout");uint8_t byte;check(recv(fd,&byte,1,0)==0,"expected EOF");
    close(fd);free(sent);free(received);
}
static void *concurrent(void *v){@autoreleasepool{roundTrip((uintptr_t)v%2,YES,NO);}return NULL;}
int main(int argc,char **argv){@autoreleasepool{
    check(argc==2,"usage: SocketProxySmoke http|socks5|deny|stall|blocked");NSString *mode=@(argv[1]);
    BOOL failure=[@[@"deny",@"stall",@"blocked"] containsObject:mode];
    uint16_t port=[mode isEqual:@"socks5"]?19092:([mode isEqual:@"deny"]?19093:([mode isEqual:@"stall"]?19094:([mode isEqual:@"blocked"]?19095:19091)));
    NSError *error=nil;check(IOSVMSocketProxyConfigure([mode isEqual:@"socks5"]?mode:@"http",@"127.0.0.1",port,nil,&error),"configure");
    if(failure){int fd=newConnection(NO,YES,NO);char request[]="payload must not go direct";send(fd,request,sizeof(request),0);
        struct pollfd p={fd,POLLIN,0};check(poll(&p,1,15000)>0,"failed proxy did not terminate");char byte;
        check(recv(fd,&byte,1,0)<=0,"failed proxy returned tunneled data");close(fd);printf("PASS %s: proxy failure closes stream, no direct fallback\n",argv[1]);return 0;}
    roundTrip(NO,NO,NO);roundTrip(NO,YES,NO);roundTrip(YES,YES,NO);roundTrip(NO,YES,YES);
    pthread_t threads[12];for(uintptr_t i=0;i<12;i++)check(pthread_create(&threads[i],NULL,concurrent,(void *)i)==0,"parallel worker");
    for(int i=0;i<12;i++)pthread_join(threads[i],NULL);
    for(int i=0;i<20;i++)roundTrip(NO,YES,NO); // repeatedly recycle fd numbers.
    int udp=socket(AF_INET,SOCK_DGRAM,0);struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons(443)};inet_pton(AF_INET,"198.51.100.42",&address.sin_addr);
    check(IOSVMSocketProxyRejectDatagram(udp,(void *)&address,sizeof(address)),"external UDP was not rejected");
    check(IOSVMSocketProxyConnect(udp,(void *)&address,sizeof(address),connect)==-1&&errno==EPROTONOSUPPORT,"UDP connect escaped proxy");
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);check(!IOSVMSocketProxyRejectDatagram(udp,(void *)&address,sizeof(address)),"loopback UDP rejected");close(udp);
    check([IOSVMSocketProxyStatus()[@"opened"] unsignedIntegerValue]>=35,"tunnel success counter missing");
    printf("PASS %s: blocking/nonblocking + kqueue; IPv4/IPv6; 256KiB binary echo; half-close; 12 parallel + 20 fd reuse; loopback; UDP rejection\n",argv[1]);
}return 0;}
