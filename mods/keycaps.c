/* keycaps.c - see keycaps.h.
 *
 * The game's main texture (1024 x 2048, 4 bytes per pixel: red, green, blue, 255) comes by here when the game
 * creates it (mods_texture_created, called by game.c). A copy is kept: new keycaps are painted into the copy and
 * the whole texture is handed to the window again (host_texture_update).
 *
 * A keycap as the game draws it, 9 x 9 pixels (c = white, d = dark, . = the texture's empty colour):
 *      .ccccccc.
 *      cdddddddc       the letter is one of the small font's own pictures (3 x 5 pixels), in the middle;
 *      cdcdcdddc       a key with a longer name gets a wider cap
 *      cdcdcdddc
 *      cddcddddc
 *      cdcdcdddc
 *      cdcdcdddc
 *      cdddddddc
 *      .ccccccc.
 * Space and the arrows have pictures of their own in the texture already: those are used as they are. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "keycaps.h"
#include "mods.h"
#include "game_api.h"
#include "../game.h"            /* host_texture_update */

enum { MAX_CAPS = 8, CAP_HEIGHT = 9, SLOT_WIDTH = 34, SLOT_HEIGHT = 10 };
static const uint8_t EMPTY[4] = { 0x00, 0xff, 0xff, 0xff }, WHITE[4] = { 0xff, 0xff, 0xff, 0xff }, DARK[4] = { 0x08, 0x00, 0x1b, 0xff };

static uint8_t *pixels;                 /* our copy of the main texture */
static int texture = -1, width, height;
static int free_x = -1, free_y;         /* an empty block of SLOT_WIDTH x MAX_CAPS * SLOT_HEIGHT pixels in it */

#define FONT0           ((int16_t *)(GAME + 0x3e5b00))     /* the small font's table: x, y, width, height per character */
#define PIXEL(x, y)     (pixels + ((size_t)(y) * width + (x)) * 4)

void mods_texture_created(int id, const void *rgba, int w, int h) {
    if (pixels || w != 1024 || h != 2048) return;           /* the main texture is the only one of this size */
    size_t size = (size_t)w * h * 4;
    pixels = malloc(size);
    if (!pixels) return;
    memcpy(pixels, rgba, size);
    texture = id;
    width = w;
    height = h;
    /* look for the empty block (near the keycaps there is none; the first one is further down) */
    for (int y = 0; y + MAX_CAPS * SLOT_HEIGHT <= h && free_x < 0; y += 2)
        for (int x = 0; x + SLOT_WIDTH <= w && free_x < 0; x += 2) {
            int empty = 1;
            for (int yy = y; yy < y + MAX_CAPS * SLOT_HEIGHT && empty; yy++)
                for (int xx = x; xx < x + SLOT_WIDTH && empty; xx++)
                    empty = memcmp(PIXEL(xx, yy), EMPTY, 4) == 0;
            if (empty) { free_x = x; free_y = y; }
            else x += SLOT_WIDTH / 2 - 2;                   /* skip ahead: this stretch is in use */
        }
    if (free_x < 0) printf("keycaps: no empty space in the texture - the hints keep the game's keys\n");
}

/* what is written on a key's cap; NULL = the key has a picture of its own (*picture: x, y, width) */
static const char *cap_text(int key, const int **picture) {
    static char text[8];
    static const int space[3] = { 953, 36, 20 }, left[3] = { 953, 27, 9 }, up[3] = { 983, 16, 9 },
                     right[3] = { 969, 27, 9 }, down[3] = { 983, 26, 9 };
    *picture = key == 0x20 ? space : key == 0x25 ? left : key == 0x26 ? up : key == 0x27 ? right : key == 0x28 ? down : NULL;
    if (*picture) return NULL;
    if ((key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9')) { text[0] = (char)key; text[1] = 0; return text; }
    if (key >= 0x60 && key <= 0x69) { snprintf(text, sizeof text, "PAD%d", key - 0x60); return text; }
    return key == 0x0d ? "ENTER" : key == 0x08 ? "BACK" : key == 0x09 ? "TAB" : key == 0x2e ? "DEL" :
           key == 0x24 ? "HOME" : key == 0x23 ? "END" : key == 0x21 ? "PGUP" : key == 0x22 ? "PGDN" :
           key >= 0x6a && key <= 0x6f ? "PAD" : "?";
}

/* Paint a keycap with `text` on it into slot number `slot` of the empty block; returns its width. */
static int paint_cap(int slot, const char *text) {
    const int16_t *font = FONT0;
    int x0 = free_x, y0 = free_y + slot * SLOT_HEIGHT, text_width = 0;
    for (const char *c = text; *c; c++) text_width += font[(uint8_t)*c * 4 + 2] + (c[1] ? 1 : 0);
    int cap = text_width + 4 < 9 ? 9 : text_width + 4;
    if (cap > SLOT_WIDTH) cap = SLOT_WIDTH;
    for (int y = 0; y < SLOT_HEIGHT; y++)
        for (int x = 0; x < SLOT_WIDTH; x++) memcpy(PIXEL(x0 + x, y0 + y), EMPTY, 4);
    for (int y = 0; y < CAP_HEIGHT; y++)
        for (int x = 0; x < cap; x++) {
            int edge_x = x == 0 || x == cap - 1, edge_y = y == 0 || y == CAP_HEIGHT - 1;
            if (edge_x && edge_y) continue;                 /* the four corners stay empty */
            memcpy(PIXEL(x0 + x, y0 + y), edge_x || edge_y ? WHITE : DARK, 4);
        }
    int x = x0 + (cap - text_width) / 2;
    for (const char *c = text; *c; c++) {                   /* each letter: the white pixels of its picture in the font */
        const int16_t *glyph = font + (uint8_t)*c * 4;
        for (int gy = 0; gy < glyph[3] && gy < CAP_HEIGHT - 4; gy++)
            for (int gx = 0; gx < glyph[2] && x + gx < x0 + cap - 1; gx++)
                if (memcmp(PIXEL(glyph[0] + gx, glyph[1] + gy), WHITE, 4) == 0) memcpy(PIXEL(x + gx, y0 + 2 + gy), WHITE, 4);
        x += glyph[2] + 1;
    }
    return cap;
}

void keycaps_set(int count, const int *characters, const int *keys) {
    static int16_t original[256][4];
    static uint8_t saved[256];
    if (!pixels || free_x < 0) return;
    int16_t *font = FONT0;
    int painted = 0;
    for (int i = 0; i < count && i < MAX_CAPS; i++) {
        int16_t *entry = font + (characters[i] & 0xff) * 4;
        if (!saved[characters[i] & 0xff]) {                 /* the game's own picture, for going back to it */
            memcpy(original[characters[i] & 0xff], entry, sizeof original[0]);
            saved[characters[i] & 0xff] = 1;
        }
        const int *picture;
        const char *text = keys[i] ? cap_text(keys[i], &picture) : NULL;
        if (!keys[i]) {
            memcpy(entry, original[characters[i] & 0xff], sizeof original[0]);
        } else if (!text) {
            entry[0] = (int16_t)picture[0]; entry[1] = (int16_t)picture[1]; entry[2] = (int16_t)picture[2]; entry[3] = CAP_HEIGHT;
        } else {
            entry[2] = (int16_t)paint_cap(i, text);
            entry[0] = (int16_t)free_x; entry[1] = (int16_t)(free_y + i * SLOT_HEIGHT); entry[3] = CAP_HEIGHT;
            painted = 1;
        }
    }
    if (painted) host_texture_update(texture, pixels, width, height);
}
