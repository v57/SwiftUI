// The Secret Service calls SecretService.swift makes, in plain C types (no GLib types reach Swift).
#ifndef CSECRETSERVICE_H
#define CSECRETSERVICE_H

#include <stddef.h>
#include <stdint.h>

/// Results: 0 done, 1 no such item, -1 failed (`*error` holds a message to free with v57_secret_free).
int v57_secret_store(const char *service, const char *account, const char *label, const uint8_t *data, size_t length,
                     char **error);
int v57_secret_lookup(const char *service, const char *account, uint8_t **data, size_t *length, char **error);
int v57_secret_clear(const char *service, const char *account, char **error);

typedef void (*v57_secret_item_callback)(void *context, const char *account, const uint8_t *data, size_t length);
/// Calls `callback` for every item of `service`.
int v57_secret_search(const char *service, void *context, v57_secret_item_callback callback, char **error);

void v57_secret_free(void *pointer);

#endif
