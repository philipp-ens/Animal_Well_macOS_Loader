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

/* ---- signing in (the login is then kept in the macOS Keychain) ----
 * The saved login belongs to the build of the program that made it: after an update of the program
 * steamcloud_signed_in says 0 and the user signs in again. That way macOS never shows its "allow access to the
 * Keychain?" dialog (see steamcloud.m). */

/* Called with a web address that has to be shown as a QR code for the Steam mobile app (Steam Guard tab,
 * "Scan a QR code"). Steam replaces the address about every half minute: the function is then called again. */
typedef void (*steamcloud_qr_fn)(const char *address, void *context);

/* Start a QR sign-in and wait until the user approved it in the Steam mobile app. 1 = signed in and the login
 * saved, 0 = not (timeout, no network, ...). The password is never involved. */
int  steamcloud_sign_in(steamcloud_qr_fn show_qr, void *context, int timeout_seconds, char *error, size_t error_size);

/* Sign in with the account name and password instead - for people without the Steam mobile app. The password is
 * sent to Steam only, encrypted with Steam's own key, and is not kept. 1 = signed in and the login saved.
 *
 * An account with Steam Guard needs a second step, for which `confirm` is called:
 *   STEAMCLOUD_CODE_FROM_EMAIL   Steam emailed a code       -> put it into `code`, return 1 (0 = give up)
 *   STEAMCLOUD_CODE_FROM_APP     the code the Steam mobile app shows under Steam Guard -> the same
 *   STEAMCLOUD_APPROVE_IN_APP    the user has to approve the sign-in in the Steam mobile app  -> tell them, return
 *   STEAMCLOUD_APPROVE_BY_EMAIL  ... or with the link Steam emailed                              1 at once (0 = give up);
 *                                the function then waits until they did (`code` is NULL here)
 * `hint` is a short text from Steam (for an email code: where it was sent) or "That code was not right." */
typedef enum {
    STEAMCLOUD_CODE_FROM_EMAIL = 2, STEAMCLOUD_CODE_FROM_APP = 3, STEAMCLOUD_APPROVE_IN_APP = 4, STEAMCLOUD_APPROVE_BY_EMAIL = 5
} steamcloud_confirmation;
typedef int (*steamcloud_confirm_fn)(steamcloud_confirmation kind, const char *hint, char *code, size_t code_size, void *context);
int  steamcloud_sign_in_password(const char *account_name, const char *password, steamcloud_confirm_fn confirm, void *context,
                                 int timeout_seconds, char *error, size_t error_size);

/* Make a sign-in that is waiting (on another thread) give up; it then returns 0 within a second. */
void steamcloud_cancel_sign_in(void);

/* 1 if a login is saved; `account_name` (may be NULL) then receives the Steam account name. */
int  steamcloud_signed_in(char *account_name, size_t account_name_size);

/* 1 if the Keychain holds the login of another build of the program - one this build cannot use. Together with
 * steamcloud_signed_in saying 0 that means: the user was signed in and an update signed them out.
 * steamcloud_sign_out removes such a login too. */
int  steamcloud_other_build_login(void);

/* Forget the saved login. (The sign-in stays listed in the account's Steam Guard device list until the user
 * removes it there.) */
void steamcloud_sign_out(void);

/* ---- the connection ---- */

/* Connect to Steam's network and log on with the saved login. 1 = connected and logged on. */
int  steamcloud_connect(char *error, size_t error_size);
/* After steamcloud_connect returned 0: 1 if Steam answered that it no longer accepts the saved login, only a new sign-in helps then; 0 for anything
 * else (no network, ...). */
int  steamcloud_login_rejected(void);
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

/* Upload a file: it replaces the cloud file of that name, or becomes a new one. 1 = Steam has it.
 *   time       when the contents were last changed, seconds since 1970 (the file's modification time)
 *   platforms  which systems Steam syncs the file to - for a Windows game's save: STEAMCLOUD_WINDOWS */
#define STEAMCLOUD_WINDOWS        1u
#define STEAMCLOUD_ALL_PLATFORMS  0xffffffffu
int  steamcloud_upload(uint32_t appid, const char *name, const uint8_t *contents, size_t size, uint64_t time,
                       uint32_t platforms, char *error, size_t error_size);

/* Remove a cloud file. 1 = done. */
int  steamcloud_delete(uint32_t appid, const char *name, char *error, size_t error_size);

/* ---- keeping one local file and one cloud file the same ----
 *
 * steamcloud_sync compares the local file with the cloud file and brings the older side up to date. To know
 * which side changed it remembers, in "<local file>.cloudsync", the checksum both sides had after the last sync:
 *
 *   both the same                          -> nothing to do
 *   only the cloud changed since then      -> download (the local file is kept as "<local file>.before-download")
 *   only the local file changed since then -> upload
 *   one side does not exist                -> it gets the other side's file
 *   both changed, or nothing is remembered -> a conflict: nothing is touched unless `choice` says which side wins.
 *                                             If the local file wins, the cloud's version is first saved as
 *                                             "<local file>.cloud-version"; if the cloud wins, the local file is
 *                                             kept as "<local file>.before-download".
 * Call it while connected (steamcloud_connect), and never while the game is running. */
typedef enum {
    STEAMCLOUD_SYNC_FAILED,     /* `error` says why; nothing was changed */
    STEAMCLOUD_IN_SYNC,         /* both sides already were the same */
    STEAMCLOUD_DOWNLOADED,      /* the local file was replaced by the cloud's */
    STEAMCLOUD_UPLOADED,        /* the cloud file was replaced by the local one */
    STEAMCLOUD_CONFLICT         /* both sides changed and `choice` was STEAMCLOUD_ASK: `conflict` is filled in */
} steamcloud_sync_result;
typedef enum { STEAMCLOUD_ASK, STEAMCLOUD_KEEP_LOCAL, STEAMCLOUD_KEEP_CLOUD } steamcloud_choice;
typedef struct {
    uint64_t local_time, cloud_time;    /* when each side was last changed, seconds since 1970: for asking the user */
} steamcloud_conflict;

steamcloud_sync_result steamcloud_sync(uint32_t appid, const char *cloud_name, const char *local_file, uint32_t platforms,
                                       steamcloud_choice choice, steamcloud_conflict *conflict,
                                       char *error, size_t error_size);

/* Only look: if the local file and the cloud file are the same right now, remember that (as a sync would) and
 * return 1; otherwise return 0. Changes neither file, so unlike steamcloud_sync it may be called while the game
 * is running - used right after a sign-in, so that the first real sync knows where both sides started. */
int  steamcloud_remember_if_same(uint32_t appid, const char *cloud_name, const char *local_file,
                                 char *error, size_t error_size);

#endif
