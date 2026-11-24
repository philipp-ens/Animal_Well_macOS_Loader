/* steam_cloud.c - the option "steam cloud" of the "mods" submenu: the Steam Cloud sync's sign-in, shown as a
 * page of the game's own menu.
 *
 * The sync itself (each time before the game starts and after it has ended) is in main.m; the Steam side is
 * steamcloud/steamcloud.m. Here: signing in (by QR code, or with account name and password), signing out, and -
 * right after a sign-in - comparing the save here with the one in the Steam Cloud and letting the user choose
 * if they differ.
 *
 * Everything that talks to Steam blocks, so it runs as a "job" on a thread of its own. The page (page(), once
 * per frame on the game's thread) only shows where things stand: `state` says which screen is up, and a job
 * that is done asks for the next screen with finish(). What both threads touch is guarded by `lock`. */
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "../option.h"
#include "../ui.h"
#include "../host.h"
#include "../game_api.h"
#include "../notify/notify.h"   /* its colours */
#include "../../game.h"         /* game_lock_save */
#include "steamcloud.h"

enum {
    HOME,           /* signed in or not, and what can be done */
    QR,             /* the QR code, until the sign-in was approved in the Steam mobile app */
    NAME, PASSWORD, /* typing the account name, then the password */
    SIGNING,        /* the password sign-in is under way (maybe waiting for an approval) */
    CODE,           /* typing a Steam Guard code */
    WORKING,        /* a job is talking to Steam: nothing to do but wait */
    CONFLICT,       /* the saves differ: which one to keep? */
    MESSAGE,        /* a text and "ok" */
    RESTART         /* a text and "ok", then the loader starts again */
};
static int state = HOME;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* what a job hands to the page (under `lock`) */
static int  next_state = -1;            /* the screen a finished job asks for; -1 = none */
static char text[700];                  /* the text of MESSAGE / RESTART / WORKING / SIGNING */
static char qr_address[512];            /* QR: the address Steam wants shown ... */
static int  qr_changed;                 /* ... and whether it is a new one */
static int  code_wanted;                /* password sign-in: 1 Steam wants a code, 2 it is in `code`, 3 the user gave up */
static char code[64], code_hint[300];
static char steam_hint[200];            /* a short text from Steam for SIGNING / CODE: where an email went */
static volatile int cancelled;          /* the user gave the sign-in up */

/* what the page keeps for itself */
static int  signed_in;                  /* HOME: as of the last look */
static char account[256];
static uint8_t qr[64 * 64];             /* QR: the code's dots */
static int  qr_side;
static ui_field field;                  /* NAME, PASSWORD, CODE */
static char name[128], password[128];
static int  only_cloud;                 /* CONFLICT: the cloud has a save, this Mac has none yet */
static uint64_t local_time, cloud_time; /* CONFLICT: when each side was last changed */

/* ------------------------------------------------------------------ jobs (on their own thread) */

/* A job's last word: the screen to show next, and its text. */
static void finish(int screen, const char *format, ...) {
    va_list arguments;
    pthread_mutex_lock(&lock);
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    next_state = screen;
    pthread_mutex_unlock(&lock);
}

static void start_job(void *(*job)(void *), intptr_t argument) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, job, (void *)argument) == 0) pthread_detach(thread);
    else finish(MESSAGE, "could not start (no thread).");
}

/* When the game's save in the Steam Cloud was last changed; 0 = the cloud has none, -1 = could not look. */
static int64_t cloud_save_time(char *error, size_t error_size) {
    enum { MAX_FILES = 512 };
    steamcloud_file *files = calloc(MAX_FILES, sizeof *files);
    int count = steamcloud_list(STEAM_APP_ID, files, MAX_FILES, error, error_size);
    int64_t changed = count < 0 ? -1 : 0;
    for (int i = 0; i < count && i < MAX_FILES; i++)
        if (!strcmp(files[i].name, CLOUD_SAVE_NAME)) changed = (int64_t)files[i].time;
    free(files);
    return changed;
}

/* Right after a sign-in: compare the save here with the one in the Steam Cloud. If they differ the user chooses
 * at once which one to keep (CONFLICT) - nothing is settled without asking. */
static void compare_saves(void) {
    char error[512] = "", who[256] = "", memory[1100];
    const char *save = mods_host_cloud_save();
    steamcloud_signed_in(who, sizeof who);
    mods_host_cloud_set_on(who);
    /* What an earlier sign-in (maybe of another account) remembered about the two sides says nothing now. Without
     * it, two saves that differ are a conflict. */
    snprintf(memory, sizeof memory, "%s.cloudsync", save);
    remove(memory);
    if (!steamcloud_connect(error, sizeof error)) {
        printf("Steam Cloud (sign-in): could not compare the saves - %s\n", error);
        finish(MESSAGE, "signed in as %s.\n\nthe steam cloud could not be reached just now: %s. it is tried again when "
                        "you quit the game.", who, error);
        return;
    }
    steamcloud_conflict conflict = { 0 };
    steamcloud_sync_result result;
    int cloud_only = 0;
    if (access(save, F_OK) != 0) {                          /* no save here yet */
        int64_t changed = cloud_save_time(error, sizeof error);
        result = changed < 0 ? STEAMCLOUD_SYNC_FAILED : changed == 0 ? STEAMCLOUD_IN_SYNC : STEAMCLOUD_CONFLICT;
        conflict.cloud_time = changed > 0 ? (uint64_t)changed : 0;
        cloud_only = changed > 0;
    } else {            /* sends this Mac's save if the cloud has none; otherwise changes nothing */
        result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, save, STEAMCLOUD_WINDOWS, STEAMCLOUD_ASK, &conflict, error, sizeof error);
    }
    steamcloud_disconnect();
    printf("Steam Cloud (sign-in): %s%s\n",
           result == STEAMCLOUD_IN_SYNC ? "the save is the same here and in the cloud" :
           result == STEAMCLOUD_UPLOADED ? "sent this Mac's save to the cloud" :
           result == STEAMCLOUD_CONFLICT ? "the saves differ" : "could not compare - ",
           result == STEAMCLOUD_SYNC_FAILED ? error : "");
    if (result == STEAMCLOUD_CONFLICT) {
        pthread_mutex_lock(&lock);
        only_cloud = cloud_only;
        local_time = conflict.local_time;
        cloud_time = conflict.cloud_time;
        pthread_mutex_unlock(&lock);
        finish(CONFLICT, "");
    } else if (result == STEAMCLOUD_IN_SYNC) {
        finish(MESSAGE, "signed in as %s.\n\nyour save here and the one in the steam cloud are the same.", who);
    } else if (result == STEAMCLOUD_UPLOADED) {
        finish(MESSAGE, "signed in as %s.\n\nthis mac's save was sent to the steam cloud.", who);
    } else {
        finish(MESSAGE, "signed in as %s.\n\nthe saves could not be compared just now: %s. it is tried again when you "
                        "quit the game.", who, error);
    }
}

/* What both ways of signing in end with. */
static void after_sign_in(int ok, const char *error) {
    if (cancelled) { finish(HOME, ""); return; }
    if (!ok) {
        printf("Steam Cloud (sign-in): did not work - %s\n", error);
        finish(MESSAGE, "the sign-in did not work.\n\n%s", error);
        return;
    }
    pthread_mutex_lock(&lock);
    snprintf(text, sizeof text, "comparing your save with the steam cloud...");
    next_state = WORKING;
    pthread_mutex_unlock(&lock);
    compare_saves();
}

/* steamcloud_sign_in calls this with the address to show as a QR code, again whenever Steam replaces it. */
static void show_qr(const char *address, void *context) {
    (void)context;
    pthread_mutex_lock(&lock);
    snprintf(qr_address, sizeof qr_address, "%s", address);
    qr_changed = 1;
    pthread_mutex_unlock(&lock);
}

static void *job_sign_in_qr(void *unused) {
    char error[512] = "";
    (void)unused;
    int ok = steamcloud_sign_in(show_qr, NULL, 300, error, sizeof error);
    after_sign_in(ok, error);
    return NULL;
}

/* steamcloud_sign_in_password calls this when the account has Steam Guard. */
static int confirm(steamcloud_confirmation kind, const char *hint, char *answer, size_t answer_size, void *context) {
    (void)context;
    pthread_mutex_lock(&lock);
    snprintf(steam_hint, sizeof steam_hint, "%s", hint ? hint : "");
    if (kind == STEAMCLOUD_APPROVE_IN_APP || kind == STEAMCLOUD_APPROVE_BY_EMAIL) {     /* nothing to type: just say what to do */
        snprintf(text, sizeof text, "%s", kind == STEAMCLOUD_APPROVE_IN_APP
                 ? "now approve the sign-in in the steam mobile app on your phone."
                 : "steam has emailed you a link. open it to approve the sign-in.");
        pthread_mutex_unlock(&lock);
        return 1;
    }
    snprintf(code_hint, sizeof code_hint, "%s",
             kind == STEAMCLOUD_CODE_FROM_EMAIL ? "steam has emailed you a code. type it, then press return."
                                                : "type the code the steam mobile app shows under steam guard, then press return.");
    code_wanted = 1;
    pthread_mutex_unlock(&lock);
    while (code_wanted == 1 && !cancelled) usleep(50000);  /* the page takes it from here (CODE) */
    pthread_mutex_lock(&lock);
    int given = code_wanted == 2;
    if (given) snprintf(answer, answer_size, "%s", code);
    memset(code, 0, sizeof code);
    code_wanted = 0;
    pthread_mutex_unlock(&lock);
    return given;
}

static void *job_sign_in_password(void *unused) {
    char error[512] = "";
    (void)unused;
    int ok = steamcloud_sign_in_password(name, password, confirm, NULL, 300, error, sizeof error);
    memset(password, 0, sizeof password);                   /* it went to Steam; it is not kept */
    after_sign_in(ok, error);
    return NULL;
}

/* The user's answer to CONFLICT. Taking the cloud's save happens while the game runs, and the game keeps its
 * save in memory: it would write its old save over the new file the next time it saves. So the game's saving is
 * switched off first (game_lock_save), the file is replaced, and the loader starts again - the game then reads
 * the cloud's save like any other. */
static void *job_keep(void *which) {
    steamcloud_choice choice = (steamcloud_choice)(intptr_t)which;
    char error[512] = "";
    const char *save = mods_host_cloud_save();
    if (choice == STEAMCLOUD_KEEP_CLOUD) game_lock_save();
    steamcloud_sync_result result = STEAMCLOUD_SYNC_FAILED;
    if (steamcloud_connect(error, sizeof error)) {
        result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, save, STEAMCLOUD_WINDOWS, choice, NULL, error, sizeof error);
        steamcloud_disconnect();
    }
    printf("Steam Cloud (sign-in): %s%s\n",
           result == STEAMCLOUD_DOWNLOADED ? "took the cloud's save (the one that was here is kept as .before-download)" :
           result == STEAMCLOUD_UPLOADED ? "sent this Mac's save to the cloud" : "sync failed - ",
           result == STEAMCLOUD_DOWNLOADED || result == STEAMCLOUD_UPLOADED ? "" : error);
    if (choice == STEAMCLOUD_KEEP_CLOUD) {                  /* only a new start makes the game save again - also if it failed */
        if (result == STEAMCLOUD_DOWNLOADED)
            finish(RESTART, "the steam cloud's save is in place. the save that was here is kept as a backup file in the "
                            "save folder.\n\nthe game starts again now.");
        else
            finish(RESTART, "the steam cloud's save could not be fetched: %s.\n\nyour save on this mac is as it was. the "
                            "game starts again now.", error);
    } else if (result == STEAMCLOUD_UPLOADED) {
        finish(MESSAGE, "this mac's save was sent to the steam cloud. the cloud's version is kept as a backup file in the "
                        "save folder.");
    } else {
        finish(MESSAGE, "this mac's save could not be sent just now: %s. it is tried again when you quit the game.", error);
    }
    return NULL;
}

/* ------------------------------------------------------------------ the page (on the game's thread) */

static int enabled = -1;                /* the switch "steam cloud sync: on / off" (kept by the loader); -1 = not looked yet */
static void set_enabled(int on) { enabled = on; mods_host_cloud_set_enabled(on); }

static int sync_on = -1;                /* for the line on the main menu: is a sign-in saved? -1 = not looked yet */

static void show(int screen) {
    state = screen;
    GAME_INT(MENU_ROW) = 0;
    ui_field_end();
    if (screen == HOME) {
        signed_in = sync_on = steamcloud_signed_in(account, sizeof account);
        enabled = mods_host_cloud_enabled();
    }
    if (screen == NAME) ui_field_begin(&field, 0);
    if (screen == PASSWORD || screen == CODE) ui_field_begin(&field, screen == PASSWORD);
}

static void say(int screen, const char *words) {
    pthread_mutex_lock(&lock);
    snprintf(text, sizeof text, "%s", words);
    pthread_mutex_unlock(&lock);
    show(screen);
}

static void date_text(uint64_t seconds_since_1970, char *out, size_t size) {
    time_t when = (time_t)seconds_since_1970;
    struct tm parts;
    localtime_r(&when, &parts);
    strftime(out, size, "%d %b %Y, %H:%M", &parts);
    for (char *c = out; *c; c++) if (*c >= 'A' && *c <= 'Z') *c += 'a' - 'A';       /* the page is all small letters */
}

static void chosen(void) { show(HOME); }

/* The first option of HOME is the switch: only while the sync is switched on are signing in and out offered. */
static void page_home(void) {
    static const char *const off_options[] = { "steam cloud sync: off" };
    static const char *const signed_out_options[] = { "steam cloud sync: on", "sign in with qr code", "sign in with password" };
    static const char *const signed_in_options[] = { "steam cloud sync: on", "sign out" };
    char words[700];
    int choice, y;
    if (!mods_host_cloud_save()) {                          /* a test run with a save of its own */
        y = ui_text(160, 44, 280, UI_WHITE, "this run uses a save file of its own and does not sync.");
        if (ui_cancel_pressed()) mods_close_page();
    } else if (!enabled) {
        choice = ui_options(56, off_options, 1);
        if (choice == 0) set_enabled(1);
        else if (ui_cancel_pressed()) mods_close_page();
    } else if (signed_in) {
        snprintf(words, sizeof words, "signed in as %s.", account);
        y = ui_text(160, 44, 280, UI_WHITE, words);
        choice = ui_options(y + 8, signed_in_options, 2);
        if (choice == 0) {
            set_enabled(0);
        } else if (choice == 1) {
            steamcloud_sign_out();
            mods_host_cloud_set_on(NULL);                   /* the user's own doing: nothing to tell them later */
            say(MESSAGE, "signed out.");
        } else if (ui_cancel_pressed()) {
            mods_close_page();
        }
    } else {
        y = ui_text(160, 40, 290, UI_WHITE, "");
        choice = ui_options(y + 8, signed_out_options, 3);
        if (choice == 0) {
            set_enabled(0);
        } else if (choice == 1) {
            cancelled = 0;
            qr_side = 0;
            show(QR);
            start_job(job_sign_in_qr, 0);
        } else if (choice == 2) {
            show(NAME);
        } else if (ui_cancel_pressed()) {
            mods_close_page();
        }
    }
}

static void page_qr(void) {
    static const char *const cancel[] = { "cancel" };
    char address[sizeof qr_address] = "";
    pthread_mutex_lock(&lock);
    if (qr_changed) { memcpy(address, qr_address, sizeof address); qr_changed = 0; }
    pthread_mutex_unlock(&lock);
    if (address[0]) qr_side = mods_host_qr(address, qr, 64);

    int below = 70;                                         /* the y below what is drawn so far */
    if (qr_side > 0) {
        /* black dots on a white square, centred; each row is drawn as runs of dark dots. 2 screen pixels per dot:
         * the window shows the 320 x 180 screen several times enlarged, which keeps the code easy to scan */
        int dot = qr_side <= 40 ? 2 : 1, size = qr_side * dot, left = 160 - size / 2, top = 52;
        ui_rect(left - dot, top - dot, size + 2 * dot, size + 2 * dot, UI_WHITE);
        for (int y = 0; y < qr_side; y++)
            for (int x = 0; x < qr_side; x++) {
                if (!qr[y * qr_side + x]) continue;
                int run = 1;
                while (x + run < qr_side && qr[y * qr_side + x + run]) run++;
                ui_rect(left + x * dot, top + y * dot, run * dot, dot, 0xff000000);
                x += run;
            }
        /* the instructions as a small grey footer below the code */
        below = ui_text(160, top + size + dot + 6, 280, UI_GREY,
                        "open the steam app on your phone, go to the steam guard tab - the shield -, choose "
                        "scan a qr code and scan this code. then approve the sign-in on your phone.");
    } else {
        below = ui_text(160, 70, 280, UI_WHITE, "asking steam for a qr code...");
    }
    if (ui_options(below + 8, cancel, 1) == 0 || ui_cancel_pressed()) {
        cancelled = 1;
        steamcloud_cancel_sign_in();                        /* the job then ends within a second and asks for HOME */
        say(WORKING, "cancelling...");
    }
}

/* NAME, PASSWORD and CODE: one typed line. Return goes on, escape (or the cancel button of a controller) back. */
static void page_typing(void) {
    char words[400], hint[sizeof steam_hint];
    pthread_mutex_lock(&lock);
    snprintf(words, sizeof words, "%s",
             state == NAME ? "type your steam account name, then press return." :
             state == PASSWORD ? "type your password, then press return." : code_hint);
    snprintf(hint, sizeof hint, "%s", state == CODE ? steam_hint : "");
    pthread_mutex_unlock(&lock);
    int y = ui_text(160, 44, 290, UI_WHITE, words);
    if (hint[0]) y = ui_line(y + 4, UI_GREY, hint);         /* where the email went: may have signs the small font lacks */
    ui_field_draw(y + 8, &field);
    ui_text(160, 150, 290, UI_GREY, "return: go on     escape: back");

    int done = field.done ? field.done : ui_cancel_pressed() ? -1 : 0;
    if (state == NAME) {
        if (done > 0 && field.text[0]) { snprintf(name, sizeof name, "%s", field.text); show(PASSWORD); }
        else if (done > 0) field.done = 0;                  /* nothing typed yet */
        else if (done < 0) show(HOME);
    } else if (state == PASSWORD) {
        if (done > 0 && field.text[0]) {
            snprintf(password, sizeof password, "%s", field.text);
            memset(&field, 0, sizeof field);
            cancelled = 0;
            code_wanted = 0;
            steam_hint[0] = 0;
            say(SIGNING, "signing in to steam...");
            start_job(job_sign_in_password, 0);
        } else if (done > 0) field.done = 0;
        else if (done < 0) { memset(&field, 0, sizeof field); show(HOME); }
    } else if (done) {                                      /* CODE */
        pthread_mutex_lock(&lock);
        if (done > 0 && field.text[0]) { snprintf(code, sizeof code, "%s", field.text); code_wanted = 2; }
        else { cancelled = 1; code_wanted = 3; }
        pthread_mutex_unlock(&lock);
        if (done > 0 && field.text[0]) say(SIGNING, "signing in to steam...");
        else { steamcloud_cancel_sign_in(); say(WORKING, "cancelling..."); }
    }
}

static void page_signing(void) {
    static const char *const cancel[] = { "cancel" };
    char words[sizeof text], hint[sizeof steam_hint];
    pthread_mutex_lock(&lock);
    memcpy(words, text, sizeof words);
    memcpy(hint, steam_hint, sizeof hint);
    int wants_code = code_wanted == 1;
    pthread_mutex_unlock(&lock);
    if (wants_code) { show(CODE); return; }
    int y = ui_text(160, 60, 280, UI_WHITE, words);
    if (hint[0]) ui_line(y + 4, UI_GREY, hint);
    if (ui_options(146, cancel, 1) == 0 || ui_cancel_pressed()) {
        cancelled = 1;
        steamcloud_cancel_sign_in();
        say(WORKING, "cancelling...");
    }
}

static void page_conflict(void) {
    static const char *const both[] = { "use the steam cloud's and restart", "use this mac's", "not now" };
    static const char *const cloud[] = { "use the steam cloud's and restart", "not now" };
    char words[700], here[64], there[64];
    date_text(cloud_time, there, sizeof there);
    if (only_cloud) {
        snprintf(words, sizeof words, "the steam cloud has a save, last changed %s. this mac has none yet. do you want to "
                                      "use it?\n\nfor that the game starts again.", there);
    } else {
        date_text(local_time, here, sizeof here);
        snprintf(words, sizeof words, "your save is different on this mac and in the steam cloud.\nthis mac: last changed "
                                      "%s\nsteam cloud: last changed %s\nwhich one do you want to keep? the other one is "
                                      "kept as a backup file. to use the steam cloud's the game starts again: what you "
                                      "played since you last saved is lost.", here, there);
    }
    int y = ui_text(160, 36, 300, UI_WHITE, words);
    int choice = ui_options(y + 6, only_cloud ? cloud : both, only_cloud ? 2 : 3);
    if (choice == 0) {
        say(WORKING, "fetching the steam cloud's save...");
        start_job(job_keep, STEAMCLOUD_KEEP_CLOUD);
    } else if (choice == 1 && !only_cloud) {
        say(WORKING, "sending this mac's save to the steam cloud...");
        start_job(job_keep, STEAMCLOUD_KEEP_LOCAL);
    } else if (choice >= 0 || ui_cancel_pressed()) {     /* not now */
        say(MESSAGE, "nothing was changed. you are asked again when you quit the game.");
    }
}

static void page_message(void) {
    static const char *const ok[] = { "ok" };
    char words[sizeof text];
    pthread_mutex_lock(&lock);
    memcpy(words, text, sizeof words);
    pthread_mutex_unlock(&lock);
    int y = ui_text(160, 44, 290, UI_WHITE, words);
    if (state == WORKING) return;                           /* a job is at it: it says what comes next */
    if (ui_options(y + 8, ok, 1) == 0 || ui_cancel_pressed()) {
        if (state == RESTART) mods_host_restart();
        else show(HOME);
    }
}

static void page(void) {
    pthread_mutex_lock(&lock);
    int wanted = next_state;
    next_state = -1;
    pthread_mutex_unlock(&lock);
    if (wanted >= 0) show(wanted);

    ui_title("steam cloud");
    switch (state) {
    case HOME:      page_home(); break;
    case QR:        page_qr(); break;
    case NAME: case PASSWORD: case CODE: page_typing(); break;
    case SIGNING:   page_signing(); break;
    case CONFLICT:  page_conflict(); break;
    default:        page_message(); break;                  /* WORKING, MESSAGE, RESTART */
    }
}

/* Every frame: on the main menu, a small line that says whether the sync is on - green if a sign-in is saved,
 * red if not. It is only there while the switch on the page above is on. Looking for the sign-in asks the Keychain, so that is done once and then again
 * whenever the page above shows its first screen (which is where signing in and out end). */
static void frame(void) {
    if (GAME_INT(GAME_MODE) != 2 || GAME_INT(MENU_ID) != 1) return;
    if (enabled < 0) enabled = mods_host_cloud_enabled();
    if (!enabled) return;                       /* switched off: no line at all */
    if (sync_on < 0) sync_on = mods_host_cloud_save() && steamcloud_signed_in(NULL, 0);
    push_layer(0x29);                           /* the layer of the menus' texts */
    ui_text_left(4, 5, 5, sync_on ? NOTIFY_GREEN : NOTIFY_RED, sync_on ? "cloud on" : "cloud off");
    pop_layer();
}

const mod_option mod_option_steam_cloud = { "steam cloud", chosen, page, frame };
