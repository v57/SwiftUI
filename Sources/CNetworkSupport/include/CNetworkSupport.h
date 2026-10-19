// The system headers the Network stand-in needs: Winsock and SChannel (SSPI) on Windows, BSD sockets elsewhere.
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
