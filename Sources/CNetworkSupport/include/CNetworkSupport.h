// The system headers the Network stand-in needs: Winsock and SChannel (SSPI) on Windows, BSD sockets elsewhere, and
// on Linux a small TLS client over OpenSSL (tls.c; OpenSSL's headers stay out of Swift).
#pragma once

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#define SECURITY_WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <sspi.h>
#define SCHANNEL_USE_BLACKLISTS
#include <subauth.h>
#include <schannel.h>

/// UNISP_NAME_W as a function (Swift can't import the wide string macro).
static inline const wchar_t *cns_unisp_name(void) { return UNISP_NAME_W; }
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#endif

#if defined(__linux__) && !defined(__ANDROID__)
#include <stddef.h>

/// A TLS client over memory buffers: encrypted bytes go in with `cns_tls_feed` and come out with `cns_tls_output`,
/// so the caller moves them over any stream.
typedef struct cns_tls cns_tls;

#define CNS_TLS_DONE 1
#define CNS_TLS_WANT_INPUT 0
#define CNS_TLS_ERROR -1
#define CNS_TLS_CLOSED -2
#define CNS_TLS_UNTRUSTED -3

/// A client for `server_name` (SNI and the name the certificate must match; an IP address is matched as one).
/// `alpn` is the wire-format protocol list. `verify`: check the chain against the system's roots and the name.
cns_tls *cns_tls_new(const char *server_name, const unsigned char *alpn, unsigned alpn_length, int verify);
void cns_tls_free(cns_tls *tls);
/// One handshake step: CNS_TLS_DONE, CNS_TLS_WANT_INPUT, CNS_TLS_UNTRUSTED or CNS_TLS_ERROR.
int cns_tls_handshake(cns_tls *tls);
/// Encrypted bytes from the peer.
int cns_tls_feed(cns_tls *tls, const void *bytes, size_t count);
/// Encrypted bytes waiting to be sent.
size_t cns_tls_output_count(cns_tls *tls);
/// Takes up to `capacity` encrypted bytes; returns how many.
size_t cns_tls_output(cns_tls *tls, void *buffer, size_t capacity);
/// Encrypts application data (into the output). Returns `count`, or CNS_TLS_ERROR.
int cns_tls_write(cns_tls *tls, const void *bytes, int count);
/// Decrypts application data: a count above 0, CNS_TLS_WANT_INPUT, CNS_TLS_CLOSED (close_notify) or CNS_TLS_ERROR.
int cns_tls_read(cns_tls *tls, void *buffer, int capacity);
/// The protocol the server picked with ALPN (not NUL-terminated), or NULL.
const unsigned char *cns_tls_alpn(cns_tls *tls, unsigned *length);
/// The last OpenSSL error on this thread, for messages.
unsigned long cns_tls_last_error(char *message, size_t capacity);
#endif
