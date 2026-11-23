/* mods.c - changes to the game itself (experiments); see mods.h.
 * Every address here is an rva in the one supported build of Animal Well.exe (game.c checks the file). */
#include <stdio.h>
#include <string.h>
#include "mods.h"

static uint8_t *image;
#define AT(rva) (image + (rva))

/* The line "billy basso / bigmode 2024" on the title screen. It is a 16-bit string in .rdata (rva 0x20bf0c0) with
 * the next string right behind it, so it cannot grow where it is. Instead:
 *   - the new text goes into unused memory: .rdata's contents end at rva 0x20ce35c, but its last page reaches to
 *     0x20cf000 - the rest is zero and nothing points there;
 *   - the one instruction that loads the old string's address, in main_menu at rva 0x1f61f
 *         4c 8d 05 <4 bytes>      lea r8, [rip + distance]
 *     gets a new distance. It counts from the end of the instruction (rva 0x1f626) to the string. */
static void mod_title_credit(const char *text) {
    const uint32_t lea = 0x1f61f, lea_end = 0x1f626, cave = 0x20ce360, cave_end = 0x20cf000;
    size_t length = strlen(text);
    if (memcmp(AT(lea), "\x4c\x8d\x05", 3) != 0 || cave + (length + 1) * 2 > cave_end) {
        fprintf(stderr, "mod_title_credit: not applied\n");
        return;
    }
    for (size_t i = 0; i <= length; i++) {                  /* plain letters -> 16-bit characters, with the ending 0 */
        uint16_t c = (uint8_t)text[i];
        memcpy(AT(cave + i * 2), &c, 2);
    }
    int32_t distance = (int32_t)(cave - lea_end);
    memcpy(AT(lea + 3), &distance, 4);
}

void mods_apply(uint8_t *mapped_image) {
    image = mapped_image;
    mod_title_credit("billy basso / bigmode 2024 / macOS port by Community");
}
