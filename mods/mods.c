/* mods.c - changes to the game itself (experiments); see mods.h.
 * Here: the patches that put the entry "mods" into the main menu, and the submenu it opens. What the submenu
 * offers is not here: every option is a file of its own in options/ (options/list.h lists them).
 * Every address is an rva in the one supported build of Animal Well.exe (game.c checks the file). */
#include <stdio.h>
#include <string.h>
#include "mods.h"
#include "game_api.h"
#include "ui.h"
#include "options/list.h"

uint8_t *mods_image;

/* Switch to another menu, the way the game's menus do it: menu_state keeps the menu we come from. */
static void open_menu(int id) {
    GAME_INT(MENU_STATE) = GAME_INT(MENU_ID);
    GAME_INT(MENU_ROW) = 0;
    GAME_INT(MENU_SCROLL) = 0;
    GAME_INT(MENU_ID) = id;
    GAME_INT(MENU_FRAMES) = 0;
}

/* Make the game function at `rva` jump straight to `fn` (which must be MSABI): 12 bytes
 * "mov rax, <address> ; jmp rax" over its start, as game.c does for the runtime functions. */
static void replace_function(uint32_t rva, void *fn) {
    uint8_t code[12] = { 0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xE0 };
    memcpy(code + 2, &fn, 8);
    memcpy(AT(rva), code, 12);
}

/* ------------------------------------------------------------------ the credit line on the title screen
 * "billy basso / bigmode 2024" is a 16-bit string in .rdata (rva 0x20bf0c0) with the next string right behind
 * it, so it cannot grow where it is. Instead:
 *   - the new text goes into unused memory: .rdata's contents end at rva 0x20ce35c, but its last page reaches to
 *     0x20cf000 - the rest is zero and nothing points there;
 *   - the one instruction that loads the old string's address, in main_menu at rva 0x1f61f
 *         4c 8d 05 <4 bytes>      lea r8, [rip + distance]
 *     gets a new distance. It counts from the end of the instruction (rva 0x1f626) to the string. */
enum { CREDIT_TEXT = 0x20ce360, CREDIT_TEXT_END = 0x20ce400 };      /* room for 79 characters */

/* plain letters -> 16-bit characters, with the ending 0; cut off if the room is too small */
static void write_text16(uint32_t rva, uint32_t end_rva, const char *text) {
    size_t room = (end_rva - rva) / 2 - 1, i;
    for (i = 0; text[i] && i < room; i++) {
        uint16_t c = (uint8_t)text[i];
        memcpy(AT(rva + i * 2), &c, 2);
    }
    memset(AT(rva + i * 2), 0, 2);
}

/* .rdata stays writable in the loader, so this also works while the game runs */
static void set_title_credit(const char *text) { write_text16(CREDIT_TEXT, CREDIT_TEXT_END, text); }

static void mod_title_credit(const char *text) {
    const uint32_t lea = 0x1f61f, lea_end = 0x1f626;
    if (memcmp(AT(lea), "\x4c\x8d\x05", 3) != 0) { fprintf(stderr, "mod_title_credit: not applied\n"); return; }
    set_title_credit(text);
    int32_t distance = (int32_t)(CREDIT_TEXT - lea_end);
    memcpy(AT(lea + 3), &distance, 4);
}

/* ------------------------------------------------------------------ a new entry in the main menu
 * main_menu (rva 0x1f050) keeps two small tables on its stack:
 *   [rsp+0x50]  the entries shown, top to bottom, as "kinds": 0 continue, 1 load game, 2 new game, 3 options, 4 quit
 *   [rsp+0x70]  8 bytes per kind; the first 4 are the kind's text id (for get_text)
 * and ebx = how many entries stand before "options". Three places are changed:
 *
 * A. where the game appends "options, quit" to the list (rva 0x1f1c7, 17 bytes):
 *        mov ecx, ebx / movabs rdx, 0x400000003 / mov [rsp+4*rcx+0x50], rdx
 *    becomes a call to stub A, which appends "options, NEW, quit" (kinds 3, 5, 4), gives kind 5 a text id of our
 *    own, and adds 1 to ebx. Everything after that - moving up and down, drawing - counts with ebx and works for
 *    one more entry without further changes.
 * B. get_text (rva 0x8f700) is replaced by mod_get_text: the same lookup, plus our text for our id.
 * C. where a chosen kind above 4 falls into the "options" case (rva 0x1f684: ja 0x1f7be) the jump goes to stub B
 *    instead: kind 5 calls menu_entry_chosen and leaves main_menu (rva 0x1f6e4), anything else goes on to 0x1f7be.
 *
 * The entry opens a submenu of its own. The game's menus are told apart by a number, menu_id (1 main menu,
 * 2 save slots, 3 options, 5 controls, 6 erase slot); menus_update (rva 0x51f00) draws the background and then
 * jumps to the menu of that number. A number it does not know ends in
 *        add rsp, 0x28 / ret             (rva 0x51fb9, 5 bytes)
 * D. those 5 bytes become a jump to stub C, which calls submenu_update. If that says "this was my number", stub C
 *    goes on where the game's own submenus end (rva 0x51fcc: draw the "back" button hint, return); otherwise it
 *    does what the 5 bytes did.
 *
 * The stubs are machine code that has to sit within reach of main_menu's 32-bit jumps, so they are copied into
 * unused memory behind the game's code: .text ends at rva 0x13b5b6, its last page at 0x13c000. They are written
 * here as assembly; whatever address they need comes from an 8-byte slot behind stub B that is filled in below. */
#define MENU_TEXT_ID 0x7000                 /* far above the game's 292 text ids */
#define SUBMENU_ID   100                    /* a menu_id the game does not use */
enum { STUB_CAVE = 0x13b5c0, STUB_CAVE_END = 0x13c000 };

extern const uint8_t mod_menu_stub_a[], mod_menu_stub_a_end[], mod_menu_stub_b[], mod_menu_stub_b_slots[], mod_menu_stub_b_end[],
                     mod_menu_stub_c[], mod_menu_stub_c_slots[], mod_menu_stub_c_end[];
__asm__(
    ".intel_syntax noprefix\n"
    ".text\n"
    "_mod_menu_stub_a:\n"                               /* reached by "call": the stack tables are 8 bytes further away */
    "    mov ecx, ebx\n"
    "    movabs rdx, 0x0000000500000003\n"              /* kinds 3, 5 */
    "    mov qword ptr [rsp + rcx*4 + 0x58], rdx\n"
    "    mov dword ptr [rsp + rcx*4 + 0x60], 4\n"       /* kind 4 */
    "    mov dword ptr [rsp + 0xa0], 0x7000\n"          /* text id of kind 5: [rsp+0x70 + 5*8] */
    "    add ebx, 1\n"
    "    ret\n"
    "_mod_menu_stub_a_end:\n"
    "_mod_menu_stub_b:\n"                               /* reached by a jump; eax = the chosen kind, above 4 */
    "    cmp eax, 5\n"
    "    jne 1f\n"
    "    call qword ptr [rip + _mod_menu_stub_b_slots]\n"
    "    jmp qword ptr [rip + _mod_menu_stub_b_slots + 8]\n"
    "1:  jmp qword ptr [rip + _mod_menu_stub_b_slots + 16]\n"
    "_mod_menu_stub_b_slots:\n"
    "    .quad 0, 0, 0\n"                               /* menu_entry_chosen, main_menu's exit, main_menu's "options" case */
    "_mod_menu_stub_b_end:\n"
    "_mod_menu_stub_c:\n"                               /* reached by a jump from menus_update, for a menu_id it does not know */
    "    call qword ptr [rip + _mod_menu_stub_c_slots]\n"
    "    test al, al\n"
    "    jne 1f\n"
    "    add rsp, 0x28\n"
    "    ret\n"
    "1:  jmp qword ptr [rip + _mod_menu_stub_c_slots + 8]\n"
    "_mod_menu_stub_c_slots:\n"
    "    .quad 0, 0\n"                                  /* submenu_update, the end of menus_update's submenu cases */
    "_mod_menu_stub_c_end:\n"
    ".att_syntax\n");

static const uint16_t menu_entry_label[] = { 'm', 'o', 'd', 's', 0 };

/* B: the game's get_text, plus our own id */
static const uint16_t *MSABI mod_get_text(int id) {
    if (id == MENU_TEXT_ID) return menu_entry_label;
    const uint16_t ***current = (const uint16_t ***)AT(0x2da4360);      /* g_cur_text_table */
    const uint16_t **english = (const uint16_t **)AT(0x2d9df00);
    if (!*current) *current = english;
    return (*current)[id] ? (*current)[id] : english[id];
}

/* C: what the new entry does */
static void MSABI menu_entry_chosen(void) { open_menu(SUBMENU_ID); }

/* D: our menus, once per frame while one is open. 1 = menu_id was ours.
 *   SUBMENU_ID        the "mods" submenu: the options of options/list.h
 *   PAGE_ID + i       the page of option i, for options that have one */
enum { OPTION_COUNT = sizeof mod_options / sizeof *mod_options, PAGE_ID = SUBMENU_ID + 1 };

void mods_close_page(void) { open_menu(SUBMENU_ID); }

static char MSABI submenu_update(void) {
    int id = GAME_INT(MENU_ID);
    if (id >= PAGE_ID && id < PAGE_ID + OPTION_COUNT && mod_options[id - PAGE_ID]->page) {
        mod_options[id - PAGE_ID]->page();
        return 1;
    }
    if (id != SUBMENU_ID) return 0;
    ui_title("mods");
    const char *labels[OPTION_COUNT];
    for (int i = 0; i < OPTION_COUNT; i++) labels[i] = mod_options[i]->label;
    int chosen = ui_options(60, labels, OPTION_COUNT);
    if (chosen >= 0) {
        if (mod_options[chosen]->page) open_menu(PAGE_ID + chosen);
        if (mod_options[chosen]->chosen) mod_options[chosen]->chosen();
    } else if (input_cancel_pressed()) {
        open_menu(1);
    }
    return 1;
}

static void mod_menu_entry(void) {
    const uint32_t append = 0x1f1c7, append_end = 0x1f1d8, above_4 = 0x1f684, unknown_menu = 0x51fb9;
    size_t size_a = (size_t)(mod_menu_stub_a_end - mod_menu_stub_a), size_b = (size_t)(mod_menu_stub_b_end - mod_menu_stub_b),
           size_c = (size_t)(mod_menu_stub_c_end - mod_menu_stub_c);
    uint32_t stub_a = STUB_CAVE, stub_b = (uint32_t)((stub_a + size_a + 15) & ~15u), stub_c = (uint32_t)((stub_b + size_b + 15) & ~15u);
    if (memcmp(AT(append), "\x89\xd9\x48\xba\x03\x00\x00\x00\x04\x00\x00\x00\x48\x89\x54\x8c\x50", 17) != 0 ||
        memcmp(AT(above_4), "\x0f\x87", 2) != 0 || memcmp(AT(unknown_menu), "\x48\x83\xc4\x28\xc3", 5) != 0 ||
        stub_c + size_c > STUB_CAVE_END) {
        fprintf(stderr, "mod_menu_entry: not applied\n");
        return;
    }
    /* the stubs, and the addresses stub B needs */
    memcpy(AT(stub_a), mod_menu_stub_a, size_a);
    memcpy(AT(stub_b), mod_menu_stub_b, size_b);
    uint64_t slots[3] = { (uint64_t)(uintptr_t)menu_entry_chosen, (uint64_t)(uintptr_t)AT(0x1f6e4), (uint64_t)(uintptr_t)AT(0x1f7be) };
    memcpy(AT(stub_b + (uint32_t)(mod_menu_stub_b_slots - mod_menu_stub_b)), slots, sizeof slots);
    memcpy(AT(stub_c), mod_menu_stub_c, size_c);
    uint64_t slots_c[2] = { (uint64_t)(uintptr_t)submenu_update, (uint64_t)(uintptr_t)AT(0x51fcc) };
    memcpy(AT(stub_c + (uint32_t)(mod_menu_stub_c_slots - mod_menu_stub_c)), slots_c, sizeof slots_c);
    /* A: "call stub A", the rest of the 17 bytes does nothing (0x90 = nop) */
    memset(AT(append), 0x90, append_end - append);
    int32_t distance = (int32_t)(stub_a - (append + 5));
    *AT(append) = 0xE8;
    memcpy(AT(append + 1), &distance, 4);
    /* C: "ja stub B" */
    distance = (int32_t)(stub_b - (above_4 + 6));
    memcpy(AT(above_4 + 2), &distance, 4);
    /* D: "jmp stub C" */
    distance = (int32_t)(stub_c - (unknown_menu + 5));
    *AT(unknown_menu) = 0xE9;
    memcpy(AT(unknown_menu + 1), &distance, 4);
    /* B */
    replace_function(0x8f700, (void *)(uintptr_t)mod_get_text);
}

void mods_apply(uint8_t *mapped_image) {
    mods_image = mapped_image;
    mod_title_credit("billy basso / bigmode 2024 / macOS by Community");
    mod_menu_entry();
}
