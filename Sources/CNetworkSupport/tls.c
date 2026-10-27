// A TLS client on OpenSSL with memory BIOs, for the Network stand-in's TLSSession on Linux.
#if defined(__linux__) && !defined(__ANDROID__)
#include "CNetworkSupport.h"
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <stdlib.h>

struct cns_tls {
    SSL_CTX *context;
    SSL *ssl;
    BIO *input;
    BIO *output;
};

cns_tls *cns_tls_new(const char *server_name, const unsigned char *alpn, unsigned alpn_length, int verify) {
    ERR_clear_error();
    SSL_CTX *context = SSL_CTX_new(TLS_client_method());
    if (!context) return NULL;
    SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION);
    if (verify) {
        SSL_CTX_set_default_verify_paths(context);
        SSL_CTX_set_verify(context, SSL_VERIFY_PEER, NULL);
    } else {
        SSL_CTX_set_verify(context, SSL_VERIFY_NONE, NULL);
    }
    SSL *ssl = SSL_new(context);
    BIO *input = BIO_new(BIO_s_mem()), *output = BIO_new(BIO_s_mem());
    if (!ssl || !input || !output) {
        if (ssl) SSL_free(ssl);
        if (input) BIO_free(input);
        if (output) BIO_free(output);
        SSL_CTX_free(context);
        return NULL;
    }
    // An empty input buffer means "more to come", not the end of the stream.
    BIO_set_mem_eof_return(input, -1);
    SSL_set_bio(ssl, input, output);
    SSL_set_connect_state(ssl);
    if (server_name && *server_name) {
        unsigned char address[16];
        int is_address = inet_pton(AF_INET, server_name, address) == 1 || inet_pton(AF_INET6, server_name, address) == 1;
        // SNI carries host names only.
        if (!is_address) SSL_set_tlsext_host_name(ssl, server_name);
        if (verify) {
            X509_VERIFY_PARAM *parameters = SSL_get0_param(ssl);
            if (is_address) {
                X509_VERIFY_PARAM_set1_ip_asc(parameters, server_name);
            } else {
                X509_VERIFY_PARAM_set_hostflags(parameters, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
                X509_VERIFY_PARAM_set1_host(parameters, server_name, 0);
            }
        }
    }
    if (alpn && alpn_length) SSL_set_alpn_protos(ssl, alpn, alpn_length);
    cns_tls *tls = calloc(1, sizeof(cns_tls));
    tls->context = context;
    tls->ssl = ssl;
    tls->input = input;
    tls->output = output;
    return tls;
}

void cns_tls_free(cns_tls *tls) {
    if (!tls) return;
    SSL_free(tls->ssl);  // frees both BIOs
    SSL_CTX_free(tls->context);
    free(tls);
}

int cns_tls_handshake(cns_tls *tls) {
    ERR_clear_error();
    int result = SSL_do_handshake(tls->ssl);
    if (result == 1) return CNS_TLS_DONE;
    switch (SSL_get_error(tls->ssl, result)) {
    case SSL_ERROR_WANT_READ:
    case SSL_ERROR_WANT_WRITE:
        return CNS_TLS_WANT_INPUT;
    default:
        return SSL_get_verify_result(tls->ssl) != X509_V_OK ? CNS_TLS_UNTRUSTED : CNS_TLS_ERROR;
    }
}

int cns_tls_feed(cns_tls *tls, const void *bytes, size_t count) {
    return BIO_write(tls->input, bytes, (int)count);
}

size_t cns_tls_output_count(cns_tls *tls) { return BIO_ctrl_pending(tls->output); }

size_t cns_tls_output(cns_tls *tls, void *buffer, size_t capacity) {
    int count = BIO_read(tls->output, buffer, (int)capacity);
    return count > 0 ? (size_t)count : 0;
}

int cns_tls_write(cns_tls *tls, const void *bytes, int count) {
    if (count == 0) return 0;
    ERR_clear_error();
    int result = SSL_write(tls->ssl, bytes, count);
    return result > 0 ? result : CNS_TLS_ERROR;
}

int cns_tls_read(cns_tls *tls, void *buffer, int capacity) {
    ERR_clear_error();
    int result = SSL_read(tls->ssl, buffer, capacity);
    if (result > 0) return result;
    switch (SSL_get_error(tls->ssl, result)) {
    case SSL_ERROR_WANT_READ:
    case SSL_ERROR_WANT_WRITE:
        return CNS_TLS_WANT_INPUT;
    case SSL_ERROR_ZERO_RETURN:
        return CNS_TLS_CLOSED;
    default:
        return CNS_TLS_ERROR;
    }
}

const unsigned char *cns_tls_alpn(cns_tls *tls, unsigned *length) {
    const unsigned char *name = NULL;
    SSL_get0_alpn_selected(tls->ssl, &name, length);
    return *length ? name : NULL;
}

unsigned long cns_tls_last_error(char *message, size_t capacity) {
    unsigned long code = ERR_peek_last_error();
    if (message && capacity) ERR_error_string_n(code, message, capacity);
    return code;
}
#endif
