/* option.h - one option of the "mods" submenu. Every option is a file of its own in options/, which defines one
 * of these; options/list.h lists them all. */
#ifndef MODS_OPTION_H
#define MODS_OPTION_H

typedef struct {
    const char *label;          /* the text shown in the submenu (plain letters) */
    void (*chosen)(void);       /* called when the option is chosen with the confirm button; NULL = nothing happens */
} mod_option;

#endif
