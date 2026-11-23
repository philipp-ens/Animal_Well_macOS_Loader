/* host.h - what mods need from the loader's Mac half (main.m implements these): things only macOS can do, and
 * what the loader knows about this run. */
#ifndef MODS_HOST_H
#define MODS_HOST_H
#include <stdint.h>

/* ---- Steam Cloud ---- */
#define STEAM_APP_ID     813230
#define CLOUD_SAVE_NAME  "%WinAppDataLocalLow%Billy Basso/Animal Well/AnimalWell.sav"      /* the save's name in the cloud */

/* The save file that is kept in line with the Steam Cloud; NULL = this run does not sync (a test run with a save
 * of its own). */
const char *mods_host_cloud_save(void);

/* Remember that the sync is on, for this account (NULL = off, the user signed out). The loader uses it to tell
 * the user when a sign-in was lost without them signing out. */
void mods_host_cloud_set_on(const char *account);

/* ---- other ---- */
/* Make a QR code of `text`. modules[y * side + x] = 1 for a dark dot; returns the side length in dots (with the
 * white border macOS adds), 0 if it could not be made or is larger than max_side. Main thread only. */
int  mods_host_qr(const char *text, uint8_t *modules, int max_side);

/* Quit the loader and start it again (used after the save file was replaced under the running game). No Steam
 * Cloud sync is done at this quit. Main thread only. */
void mods_host_restart(void);

#endif
