#include "CSecretService.h"

#include <libsecret/secret.h>
#include <stdlib.h>
#include <string.h>

/// One schema for every item: a service and an account, like a generic keychain password.
static const SecretSchema *schema(void) {
    static const SecretSchema value = {
        "dev.v57.Secret", SECRET_SCHEMA_NONE,
        {
            {"service", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {NULL, 0},
        },
    };
    return &value;
}

static GHashTable *attributes(const char *service, const char *account) {
    GHashTable *table = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    g_hash_table_insert(table, g_strdup("service"), g_strdup(service));
    if (account) g_hash_table_insert(table, g_strdup("account"), g_strdup(account));
    return table;
}

static int fail(GError *failure, char **error) {
    if (error) *error = strdup(failure && failure->message ? failure->message : "Secret Service error");
    if (failure) g_error_free(failure);
    return -1;
}

int v57_secret_store(const char *service, const char *account, const char *label, const uint8_t *data, size_t length,
                     char **error) {
    GHashTable *table = attributes(service, account);
    SecretValue *value = secret_value_new((const gchar *)data, (gssize)length, "application/octet-stream");
    GError *failure = NULL;
    gboolean ok = secret_password_storev_binary_sync(schema(), table, SECRET_COLLECTION_DEFAULT, label, value, NULL,
                                                     &failure);
    secret_value_unref(value);
    g_hash_table_unref(table);
    return ok ? 0 : fail(failure, error);
}

int v57_secret_lookup(const char *service, const char *account, uint8_t **data, size_t *length, char **error) {
    GHashTable *table = attributes(service, account);
    GError *failure = NULL;
    SecretValue *value = secret_password_lookupv_binary_sync(schema(), table, NULL, &failure);
    g_hash_table_unref(table);
    if (failure) return fail(failure, error);
    if (!value) return 1;
    gsize size = 0;
    const gchar *bytes = secret_value_get(value, &size);
    *data = malloc(size ? size : 1);
    if (size) memcpy(*data, bytes, size);
    *length = size;
    secret_value_unref(value);
    return 0;
}

int v57_secret_clear(const char *service, const char *account, char **error) {
    GHashTable *table = attributes(service, account);
    GError *failure = NULL;
    gboolean removed = secret_password_clearv_sync(schema(), table, NULL, &failure);
    g_hash_table_unref(table);
    if (failure) return fail(failure, error);
    return removed ? 0 : 1;
}

int v57_secret_search(const char *service, void *context, v57_secret_item_callback callback, char **error) {
    GHashTable *table = attributes(service, NULL);
    GError *failure = NULL;
    GList *items = secret_password_searchv_sync(
        schema(), table, SECRET_SEARCH_ALL | SECRET_SEARCH_UNLOCK | SECRET_SEARCH_LOAD_SECRETS, NULL, &failure);
    g_hash_table_unref(table);
    if (failure) return fail(failure, error);
    for (GList *item = items; item; item = item->next) {
        SecretRetrievable *retrievable = item->data;
        GHashTable *found = secret_retrievable_get_attributes(retrievable);
        const char *account = found ? g_hash_table_lookup(found, "account") : NULL;
        SecretValue *value = secret_retrievable_retrieve_secret_sync(retrievable, NULL, NULL);
        if (account && value) {
            gsize size = 0;
            const gchar *bytes = secret_value_get(value, &size);
            callback(context, account, (const uint8_t *)bytes, size);
        }
        if (value) secret_value_unref(value);
        if (found) g_hash_table_unref(found);
    }
    g_list_free_full(items, g_object_unref);
    return 0;
}

void v57_secret_free(void *pointer) { free(pointer); }
