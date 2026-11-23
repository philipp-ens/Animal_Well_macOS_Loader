/* notify.h - notifications inside the game: a small box with a line or two of text at the top left of the
 * picture, on top of whatever the game shows (title screen, menus, the game itself). notify.c has it.
 *
 *     notify("saved to the steam cloud", NOTIFY_GREEN);
 *
 * A notification stays for 5 seconds; up to 4 are shown below each other (a fifth pushes the oldest out).
 * notify may be called from any thread and at any time - also before the game has started: the notification
 * then appears with the game's first pictures. */
#ifndef MODS_NOTIFY_H
#define MODS_NOTIFY_H
#include <stdint.h>

/* A colour from red, green and blue (0..255 each). The game's colour numbers are 0xAABBGGRR. */
#define NOTIFY_RGB(r, g, b) (0xff000000u | (uint32_t)(b) << 16 | (uint32_t)(g) << 8 | (uint32_t)(r))
#define NOTIFY_WHITE    NOTIFY_RGB(255, 255, 255)
#define NOTIFY_RED      NOTIFY_RGB(255,  90,  90)
#define NOTIFY_YELLOW   NOTIFY_RGB(255, 210,  70)
#define NOTIFY_GREEN    NOTIFY_RGB(110, 220, 110)
#define NOTIFY_BLUE     NOTIFY_RGB(110, 170, 255)

/* Show `text` (plain letters; long text is broken into lines) in `color`: the text and the bar at the box's left
 * edge have that colour. */
void notify(const char *text, uint32_t color);

/* The same, staying for `seconds`. */
void notify_for(const char *text, uint32_t color, int seconds);

/* Put the drawing of the notifications into the game. mods_apply calls this once. */
void notify_install(void);

#endif
