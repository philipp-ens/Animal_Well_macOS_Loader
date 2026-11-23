/* ui.h - drawing and input for the mods' own menu pages, built from the game's functions (ui.c).
 * The screen is 320 x 180. Text is plain letters; the pages use the game's small font (font 0) for running text
 * and the font of the game's menu entries for options. */
#ifndef MODS_UI_H
#define MODS_UI_H
#include <stdint.h>

#define UI_WHITE 0xffffffffu
#define UI_GREY  0xff8c8c8cu                /* the colour of the credit line on the title screen */

/* A page's title, in the large font, where the options menu has "OPTIONS". */
void ui_title(const char *text);

/* Running text in the small font, centred around center_x, broken into lines of at most max_width pixels
 * ('\n' also starts a new line). Signs the small font lacks are replaced by similar ones. Returns the y below
 * the last line. */
int  ui_text(int center_x, int y, int max_width, uint32_t color, const char *text);

/* The same text with its lines starting at x, and the size it takes (for drawing something behind it). */
int  ui_text_left(int x, int y, int max_width, uint32_t color, const char *text);
void ui_text_size(const char *text, int max_width, int *width, int *height);

/* One centred line in the font of the game's menu entries. Unlike the small font it has every sign of the
 * keyboard (the small font lacks ( ) * _ @ and others). Returns the y below. */
int  ui_line(int y, uint32_t color, const char *text);

/* A list of options like the main menu's entries: centred, one line each, the chosen one between the two
 * animated arrows. Up and down move the choice (the game's menu_row). Returns the index of the option the
 * confirm button was pressed on, -1 if none. */
int  ui_options(int y, const char *const *labels, int count);

/* A filled rectangle. */
void ui_rect(int x, int y, int width, int height, uint32_t color);

/* A line of text the user types on the keyboard. While a field is active the keyboard goes to it and not to the
 * game (see mods_wants_typing in mods.h). */
typedef struct {
    char text[128];
    int  secret;            /* 1 = shown as stars */
    int  done;              /* 0 typing, 1 return was pressed, -1 escape */
} ui_field;
void ui_field_begin(ui_field *field, int secret);       /* empties the field and makes it the active one */
void ui_field_end(void);                                 /* no field is active any more */
int  ui_field_draw(int y, const ui_field *field);        /* the typed text with a cursor; returns the y below */

#endif
