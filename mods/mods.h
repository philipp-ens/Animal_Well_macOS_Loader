/* mods.h - changes to the game itself (experiments). mods.c has them.
 *
 * A mod changes the game in memory, after the exe is mapped and before any game code runs. The file on disk stays
 * as it is (so its fingerprint still matches), and removing a mod is removing its line in mods_apply. */
#ifndef MODS_H
#define MODS_H
#include <stdint.h>

/* Apply all mods. `image` is where the exe is mapped: the address of something in it is image + its rva.
 * game.c calls this once, while the whole image - the code too - can still be written. */
void mods_apply(uint8_t *image);

#endif
