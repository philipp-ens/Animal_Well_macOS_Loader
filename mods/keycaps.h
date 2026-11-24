/* keycaps.h - the pictures of keyboard keys in the game's button hints (keycaps.c).
 *
 * Every hint the game shows ("press X to ...") is a character of its small font: the font's table says where in
 * the game's main texture the picture of that character is. For the keyboard the characters 0x9b...0xa3 are
 * little keycaps (a space bar, Z, X, C, ESC, V, 1, 3). keycaps_set makes such a character show another key: it
 * paints a new keycap into an unused corner of the texture and points the character's table entry at it. */
#ifndef MODS_KEYCAPS_H
#define MODS_KEYCAPS_H

/* The keyboard hint characters, by what the game uses them for. */
enum {
    KEYCAP_JUMP = 0x9b, KEYCAP_INTERACT = 0x9c, KEYCAP_USE_ITEM = 0x9d, KEYCAP_INVENTORY = 0x9e,
    KEYCAP_MAP = 0xa0, KEYCAP_PREVIOUS_ITEM = 0xa2, KEYCAP_NEXT_ITEM = 0xa3
};

/* For each of `count` hint characters: show the key keys[i] (a Windows key number), or the game's own picture
 * if keys[i] is 0. At most 8 characters. Only on the game's thread, once the game runs (the font tables are in
 * its state). */
void keycaps_set(int count, const int *characters, const int *keys);

#endif
