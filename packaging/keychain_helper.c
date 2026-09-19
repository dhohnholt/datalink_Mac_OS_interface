/*
 * keychain-helper — one Keychain operation, for the frozen .app build.
 *
 * Why this exists.  macOS cannot identify an ad-hoc signed program by its
 * signature, so it records which program may read a Keychain item by file
 * path, and it notices when the bytes at that path change.  The .app is
 * re-signed on every build and replaced wholesale by every update, so the
 * app itself can never stay trusted: the teacher is asked for their login
 * password again after each update.
 *
 * The Homebrew build solves this by copying a Python interpreter to a fixed
 * path and letting the Keychain trust that.  A frozen build has no
 * interpreter to copy — the Python inside it is a shared library, not an
 * executable — so it carries this instead.  It is copied once to the same
 * fixed directory, trusted once, and left alone by later updates.
 *
 * Protocol, so that no secret is ever an argument and never reaches `ps`:
 *
 *     stdin   action \n service \n account \n [password bytes]
 *     stdout  "ok" \n [value bytes]   |   "none" \n   |   "err" \n message
 *
 * Built and signed by packaging/build_macos.sh into Contents/Helpers/.
 */

#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void emit(const char *status, const void *body, size_t length) {
    fputs(status, stdout);
    fputc('\n', stdout);
    if (body != NULL && length > 0) {
        fwrite(body, 1, length, stdout);
    }
    fflush(stdout);
}

static int fail(OSStatus status) {
    char message[128];
    snprintf(message, sizeof message, "Keychain error %d", (int)status);
    emit("err", message, strlen(message));
    return 1;
}

/* Everything on stdin, however it arrives. */
static char *slurp(size_t *out_length) {
    size_t capacity = 8192, length = 0;
    char *buffer = malloc(capacity);
    if (buffer == NULL) return NULL;
    for (;;) {
        if (length == capacity) {
            capacity *= 2;
            char *grown = realloc(buffer, capacity);
            if (grown == NULL) { free(buffer); return NULL; }
            buffer = grown;
        }
        ssize_t got = read(STDIN_FILENO, buffer + length, capacity - length);
        if (got < 0) { free(buffer); return NULL; }
        if (got == 0) break;
        length += (size_t)got;
    }
    *out_length = length;
    return buffer;
}

int main(void) {
    size_t total = 0;
    char *input = slurp(&total);
    if (input == NULL) {
        emit("err", "Could not read the request", 26);
        return 1;
    }

    /* action \n service \n account \n password... — the password may contain
       anything at all, including newlines, so only the first three are split. */
    char *field[3] = {input, NULL, NULL};
    char *password = NULL;
    size_t password_length = 0;
    int found = 0;
    for (size_t index = 0; index < total && found < 3; index++) {
        if (input[index] != '\n') continue;
        input[index] = '\0';
        found++;
        if (found < 3) field[found] = input + index + 1;
        else {
            password = input + index + 1;
            password_length = total - index - 1;
        }
    }
    if (found < 3) {
        emit("err", "Malformed request", 17);
        free(input);
        return 1;
    }

    const char *action = field[0];
    const char *service = field[1];
    const char *account = field[2];
    UInt32 service_length = (UInt32)strlen(service);
    UInt32 account_length = (UInt32)strlen(account);

    if (strcmp(action, "get") == 0) {
        void *value = NULL;
        UInt32 value_length = 0;
        OSStatus status = SecKeychainFindGenericPassword(
            NULL, service_length, service, account_length, account,
            &value_length, &value, NULL);
        if (status == errSecItemNotFound) { emit("none", NULL, 0); free(input); return 0; }
        if (status != errSecSuccess) { free(input); return fail(status); }
        emit("ok", value, value_length);
        SecKeychainItemFreeContent(NULL, value);
        free(input);
        return 0;
    }

    if (strcmp(action, "set") == 0) {
        SecKeychainItemRef existing = NULL;
        OSStatus status = SecKeychainFindGenericPassword(
            NULL, service_length, service, account_length, account,
            NULL, NULL, &existing);
        if (status == errSecSuccess && existing != NULL) {
            status = SecKeychainItemModifyAttributesAndData(
                existing, NULL, (UInt32)password_length, password);
            CFRelease(existing);
        } else {
            status = SecKeychainAddGenericPassword(
                NULL, service_length, service, account_length, account,
                (UInt32)password_length, password, NULL);
        }
        if (status != errSecSuccess) { free(input); return fail(status); }
        emit("ok", NULL, 0);
        free(input);
        return 0;
    }

    if (strcmp(action, "delete") == 0) {
        SecKeychainItemRef existing = NULL;
        OSStatus status = SecKeychainFindGenericPassword(
            NULL, service_length, service, account_length, account,
            NULL, NULL, &existing);
        if (status == errSecItemNotFound) { emit("none", NULL, 0); free(input); return 0; }
        if (status != errSecSuccess) { free(input); return fail(status); }
        status = SecKeychainItemDelete(existing);
        CFRelease(existing);
        if (status != errSecSuccess) { free(input); return fail(status); }
        emit("ok", NULL, 0);
        free(input);
        return 0;
    }

    emit("err", "Unknown action", 14);
    free(input);
    return 1;
}
