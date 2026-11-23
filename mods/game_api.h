/* game_api.h - what mods use to reach into the game: addresses inside the mapped exe, the game's own functions,
 * and fields of its state. For mods.c and the option files in options/.
 * Every address is an rva in the one supported build of Animal Well.exe (game.c checks the file); the names are
 * the ones from the decompilation. */
#ifndef MODS_GAME_API_H
#define MODS_GAME_API_H
#include <stddef.h>
#include <stdint.h>

extern uint8_t *mods_image;                 /* where the exe is mapped (set by mods_apply) */
#define AT(rva) (mods_image + (rva))        /* address of something inside it */
#define MSABI __attribute__((ms_abi))       /* "call this the Windows way": how the game's own functions are called */

/* Copy a piece of machine code into unused memory behind the game's code (.text ends at rva 0x13b5b6, its last
 * page at 0x13c000) and return the copy's rva; 0 = no room left. For stubs that the game's own code jumps to:
 * its 32-bit jumps only reach places near it. Only while mods_apply runs - afterwards the code cannot be written. */
uint32_t mods_add_code(const void *code, size_t size);

/* ---- the game's own functions, by rva ---- */
#define GAME_FN(rva, result, ...) ((result (MSABI *)(__VA_ARGS__))AT(rva))
#define set_color(argb)                 GAME_FN(0x17dc0, void, uint32_t)(argb)
#define push_layer(layer)               GAME_FN(0x17e50, void, int)(layer)
#define pop_layer()                     GAME_FN(0x17eb0, void, void)()
#define set_font(font)                  GAME_FN(0x6e2e0, void, int)(font)          /* 0 small, 1 large (menu titles) */
#define current_lang_font()             GAME_FN(0x6e2f0, uint8_t *, void)()        /* +0x2000e: short, height of a text line */
#define text_width(text)                GAME_FN(0x6e470, int, const uint16_t *)(text)
#define draw_text(x, y, text)           GAME_FN(0x6ebc0, void, int, int, const uint16_t *)(x, y, text)
#define draw_text_centered(x, y, text)  GAME_FN(0x6ecd0, void, int, int, const uint16_t *)(x, y, text)
/* a w x h picture of animation frame `frame` of sprite `sprite`; a negative w mirrors it */
#define draw_atlas_scaled(x, y, w, h, sprite, frame) \
    GAME_FN(0x1a5a0, void, int, int, int, int, uint16_t, int, uint8_t, uint8_t, uint8_t)(x, y, w, h, sprite, frame, 0, 0, 0)
#define push_color(argb)                GAME_FN(0x17de0, void, uint32_t)(argb)
#define pop_color()                     GAME_FN(0x17e40, void, void)()
#define draw_rect(x, y, w, h)           GAME_FN(0x182d0, void, int, int, int, int)(x, y, w, h)    /* in the current colour */
#define input_confirm_pressed()         GAME_FN(0x6d360, char, void)()
#define input_cancel_pressed()          GAME_FN(0x6d4a0, char, void)()
#define menu_down_repeat()              GAME_FN(0x6d740, char, void)()             /* down pressed, or held long enough to repeat */
#define menu_up_repeat()                GAME_FN(0x6d780, char, void)()

/* ---- the game's state: g_game points to it ---- */
#define GAME                (*(uint8_t **)AT(0x2d285f8))
#define GAME_INT(offset)    (*(int32_t *)(GAME + (offset)))
#define GAME_INT64(offset)  (*(int64_t *)(GAME + (offset)))
enum {
    MENU_ROW = 0x93610, MENU_SCROLL = 0x93618, MENU_STATE = 0x93640, MENU_ID = 0x93644, MENU_FRAMES = 0x93648,
    TOTAL_FRAMES = 0x46b5a0     /* 64 bits: frames since the game started */
};

#endif
