/* option.h - one option of the "mods" submenu. Every option is a file of its own in options/, which defines one
 * of these; options/list.h lists them all. */
#ifndef MODS_OPTION_H
#define MODS_OPTION_H

typedef struct {
    const char *label;          /* the text shown in the submenu (plain letters) */
    void (*chosen)(void);       /* called when the option is chosen with the confirm button; NULL = nothing to do */
    void (*page)(void);         /* NULL, or the option's own menu page: choosing the option opens it, and this is
                                   then called once per frame to draw it and handle its input (ui.h helps) */
} mod_option;

/* For an option's page: go back to the "mods" submenu. */
void mods_close_page(void);

#endif
