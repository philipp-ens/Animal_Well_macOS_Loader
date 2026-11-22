/* steamcloud.h - Steam Cloud without the Steam app: sign in to Steam, connect the way the Steam client does,
 * and work with a game's cloud files. steamcloud.m has the details; steamcloud_tool.m is a command-line test.
 *
 * Every function blocks until it is done (or a timeout passed). None may be called on the main thread of an
 * app that must stay responsive - use a background thread there.
 * Functions that can fail take `error`: a buffer that receives one line of plain text saying what went wrong.
 */
#ifndef STEAMCLOUD_H
#define STEAMCLOUD_H
#include <stddef.h>
#include <stdint.h>

/* ---- signing in (once; the login is then kept in the macOS Keychain) ---- */

/* Called with a web address that has to be shown as a QR code for the Steam mobile app (Steam Guard tab,
 * "Scan a QR code"). Steam replaces the address about every half minute: the function is then called again. */
typedef void (*steamcloud_qr_fn)(const char *address, void *context);

/* Start a QR sign-in and wait until the user approved it in the Steam mobile app. 1 = signed in and the login
 * saved, 0 = not (timeout, no network, ...). The password is never involved. */
int  steamcloud_sign_in(steamcloud_qr_fn show_qr, void *context, int timeout_seconds, char *error, size_t error_size);

/* 1 if a login is saved; `account_name` (may be NULL) then receives the Steam account name. */
int  steamcloud_signed_in(char *account_name, size_t account_name_size);

/* Forget the saved login. (The sign-in stays listed in the account's Steam Guard device list until the user
 * removes it there.) */
void steamcloud_sign_out(void);

/* ---- the connection ---- */

/* Connect to Steam's network and log on with the saved login. 1 = connected and logged on. */
int  steamcloud_connect(char *error, size_t error_size);
void steamcloud_disconnect(void);

/* ---- cloud files ---- */
typedef struct {
    char     name[512];         /* e.g. "%WinAppDataLocalLow%Billy Basso/Animal Well/AnimalWell.sav" */
    char     sha1[41];          /* of the file's contents, 40 hex digits */
    char     platforms[64];     /* which systems Steam syncs it to, e.g. "Windows" or "All" */
    uint32_t size;              /* in bytes, unpacked */
    uint64_t time;              /* last change, seconds since 1970 */
} steamcloud_file;

/* List the cloud files of one game. Returns how many there are (at most max_files are filled in), -1 on failure. */
int  steamcloud_list(uint32_t appid, steamcloud_file *files, int max_files, char *error, size_t error_size);

/* Download one cloud file (`name` as steamcloud_list gave it). Returns the file's contents, unpacked and checked
 * against Steam's checksum, and their length in *size; NULL on failure. Release the memory with free(). */
uint8_t *steamcloud_download(uint32_t appid, const char *name, size_t *size, char *error, size_t error_size);

#endif
