/* mods.h - changes to the game itself (experiments). mods.c has the patches, options/ what the "mods" submenu
 * offers.
 *
 * A mod changes the game in memory, after the exe is mapped and before any game code runs. The file on disk stays
 * as it is (so its fingerprint still matches), and removing a mod is removing its line in mods_apply. */
#ifndef MODS_H
#define MODS_H
#include <stdint.h>

/* Apply all mods. `image` is where the exe is mapped: the address of something in it is image + its rva.
 * game.c calls this once, while the whole image - the code too - can still be written. */
void mods_apply(uint8_t *image);

/* Typing into a mod's page. While mods_wants_typing() is 1 the window gives every key press to mods_typed and
 * none to the game: `text` is what the key types (NULL for the special keys below). */
enum { MODS_KEY_TEXT, MODS_KEY_RETURN, MODS_KEY_BACKSPACE, MODS_KEY_ESCAPE };
int  mods_wants_typing(void);
void mods_typed(int key, const char *text);

/* The game has created a texture: `rgba` are its width x height pixels, `texture` the number the window knows
 * it by (for host_texture_update). game.c calls this for every texture; keycaps.c keeps the main one. */
void mods_texture_created(int texture, const void *rgba, int width, int height);

/* The keyboard mod (options/keyboard.c). The window calls this for every key press that goes to the game, with
 * the key's Windows number: it returns the number the game should get in its place - the same one, or the key
 * of the action the user put on this key - or 0 if the game should not get the press at all. */
int  mods_translate_key(int windows_key);

#endif
