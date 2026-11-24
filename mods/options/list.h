/* list.h - every option of the "mods" submenu, in the order shown.
 * To add an option: a new file in this folder that defines a mod_option (see steam_cloud.c), and its two lines here. */
#include "../option.h"

extern const mod_option mod_option_steam_cloud; /* steam_cloud.c */
extern const mod_option mod_option_keyboard;    /* keyboard.c */

static const mod_option *const mod_options[] = {
    &mod_option_steam_cloud,
    &mod_option_keyboard,
};
