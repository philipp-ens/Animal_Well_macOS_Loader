/* keyboard.c - the option "keyboard" of the "mods" submenu: choose your own keys for the game's actions.
 *
 * The game asks for fixed keys (its input functions, e.g. input_jump_pressed, have the key numbers built in).
 * They are not changed. Instead the loader translates on the way in: a key you chose for an action is handed
 * to the game as that action's own key. The window calls mods_translate_key for every key press (main.m).
 *
 *   action          the game's own keys (Windows key numbers)            handed to the game as
 *   move            W A S D, the arrows, the number pad                  W A S D
 *   jump            space, pad 0  (also "confirm" in menus)              space
 *   use item        X, E, pad 5                                          X
 *   interact        Z, Q, backspace, return  (also "cancel" in menus)    Z
 *   switch items    1 (previous), 3 (next)                               1, 3
 *   map             M, V                                                 M
 *   inventory       I, R, C, 2                                           I
 * Pause (escape, P) is not on the list on purpose: escape always stays escape - it cannot be put on an action
 * either, because while a key is being chosen it means "keep it as it is".
 *
 * The game's own keys go on working next to yours - except a key you gave to another action. Giving an action
 * a key that another action is on swaps the two, so no action is ever left without a key.
 * The choices are kept in the loader's settings. */
#include <stdio.h>
#include <string.h>
#include "../option.h"
#include "../ui.h"
#include "../host.h"
#include "../mods.h"
#include "../game_api.h"

typedef struct {
    const char *name;           /* as shown on the page */
    int game_key;               /* the key the game gets for it */
    const char *setting;        /* its name in the loader's settings */
    int chosen_key;             /* the user's key (a Windows key number); 0 = none chosen */
} action;
static action actions[] = {
    { "move up",       'W',  "KeyMoveUp",       0 },
    { "move down",     'S',  "KeyMoveDown",     0 },
    { "move left",     'A',  "KeyMoveLeft",     0 },
    { "move right",    'D',  "KeyMoveRight",    0 },
    { "jump",          0x20, "KeyJump",         0 },
    { "use item",      'X',  "KeyUseItem",      0 },
    { "interact",      'Z',  "KeyInteract",     0 },
    { "previous item", '1',  "KeyPreviousItem", 0 },
    { "next item",     '3',  "KeyNextItem",     0 },
    { "map",           'M',  "KeyMap",          0 },
    { "inventory",     'I',  "KeyInventory",    0 },
};
enum { ACTIONS = sizeof actions / sizeof *actions, ESCAPE = 0x1b };

static int translation[256];    /* for each key: the key the game gets in its place; 0 = the key itself */
static int loaded;
static int waiting_for = -1;    /* the action whose key is being chosen: the next key press is it; -1 = none */

static void rebuild(void) {
    memset(translation, 0, sizeof translation);
    for (int i = 0; i < ACTIONS; i++)
        if (actions[i].chosen_key) translation[actions[i].chosen_key] = actions[i].game_key;
}

/* The key an action is on right now: the chosen one, else its own - 0 if that one was given to another action
 * (which choose() never lets happen). */
static int current_key(const action *a) {
    return a->chosen_key ? a->chosen_key : translation[a->game_key] ? 0 : a->game_key;
}

static void set_key(action *a, int key) {
    a->chosen_key = key == a->game_key ? 0 : key;          /* its own key: nothing to translate */
    mods_host_set_int(a->setting, a->chosen_key);
}

/* Put `key` on action `which`. If the key is another action's current key, the two actions swap keys: every
 * action always has a key. (Otherwise giving away the key of "jump" - which is also "confirm" in the menus -
 * would leave no way to confirm anything, this page included.) */
static void choose(int which, int key) {
    int old_key = current_key(&actions[which]);
    for (int i = 0; i < ACTIONS; i++)
        if (i != which && current_key(&actions[i]) == key) set_key(&actions[i], old_key);
    set_key(&actions[which], key);
    rebuild();
}

static void load(void) {
    if (loaded) return;
    loaded = 1;
    for (int i = 0; i < ACTIONS; i++) {
        int key = mods_host_get_int(actions[i].setting, 0);
        actions[i].chosen_key = key > 0 && key < 256 ? key : 0;
    }
    rebuild();
    /* Choices saved by the first version of this mod could leave an action without a key. Such an action gets
     * the own key of the action that took its key (the swap that was missing); if that does not work out,
     * everything goes back to the game's own keys. */
    for (int i = 0; i < ACTIONS; i++) {
        if (current_key(&actions[i])) continue;
        int freed = 0;
        for (int j = 0; j < ACTIONS; j++)
            if (actions[j].chosen_key == actions[i].game_key && !translation[actions[j].game_key]) freed = actions[j].game_key;
        if (freed) { set_key(&actions[i], freed); rebuild(); continue; }
        for (int j = 0; j < ACTIONS; j++) set_key(&actions[j], actions[j].game_key);
        rebuild();
        break;
    }
}

/* main.m, for every key press: the key the game should get (a Windows key number), or 0 for none. */
int mods_translate_key(int key) {
    load();
    if (key <= 0 || key >= 256) return key;
    if (waiting_for >= 0) {                                 /* this press is the answer: the game does not see it */
        if (key != ESCAPE) choose(waiting_for, key);
        waiting_for = -1;
        return 0;
    }
    return translation[key] ? translation[key] : key;
}

/* a key's name, for the page */
static const char *key_name(int key) {
    static char name[16];
    static const struct { int key; const char *name; } named[] = {
        { 0x20, "space" }, { 0x0d, "return" }, { 0x08, "backspace" }, { 0x09, "tab" }, { 0x1b, "escape" },
        { 0x25, "left arrow" }, { 0x26, "up arrow" }, { 0x27, "right arrow" }, { 0x28, "down arrow" },
        { 0x24, "home" }, { 0x23, "end" }, { 0x21, "page up" }, { 0x22, "page down" }, { 0x2e, "delete" },
        { 0x6a, "pad *" }, { 0x6b, "pad +" }, { 0x6d, "pad -" }, { 0x6e, "pad ." }, { 0x6f, "pad /" },
    };
    for (size_t i = 0; i < sizeof named / sizeof *named; i++) if (named[i].key == key) return named[i].name;
    if (key >= 'A' && key <= 'Z') snprintf(name, sizeof name, "%c", key - 'A' + 'a');
    else if (key >= '0' && key <= '9') snprintf(name, sizeof name, "%c", key);
    else if (key >= 0x60 && key <= 0x69) snprintf(name, sizeof name, "pad %d", key - 0x60);
    else snprintf(name, sizeof name, "key %d", key);
    return name;
}

static const char *action_key_name(const action *a) {
    int key = current_key(a);
    return key ? key_name(key) : "none";
}

static void chosen(void) { load(); waiting_for = -1; }

static void page(void) {
    static char labels[ACTIONS][48];
    const char *rows[ACTIONS + 1];
    ui_title("keyboard");
    if (waiting_for >= 0) {                                 /* the key press itself arrives in mods_translate_key */
        char words[120];
        snprintf(words, sizeof words, "press the key for: %s", actions[waiting_for].name);
        int y = ui_line(70, UI_WHITE, words);
        ui_text(160, y + 6, 280, UI_GREY, "escape: keep it as it is");
        if (input_cancel_pressed()) waiting_for = -1;       /* the cancel button of a controller */
        return;
    }
    for (int i = 0; i < ACTIONS; i++) {
        snprintf(labels[i], sizeof labels[i], "%s: %s", actions[i].name, action_key_name(&actions[i]));
        rows[i] = labels[i];
    }
    rows[ACTIONS] = "reset all";
    int choice = ui_options(36, rows, ACTIONS + 1);            /* 12 rows of 11 pixels: right below the title */
    if (choice >= 0 && choice < ACTIONS) {
        waiting_for = choice;
    } else if (choice == ACTIONS) {
        for (int i = 0; i < ACTIONS; i++) { actions[i].chosen_key = 0; mods_host_set_int(actions[i].setting, 0); }
        rebuild();
    } else if (input_cancel_pressed()) {                    /* the way back is the cancel button, as in the game's menus */
        mods_close_page();
    }
}

const mod_option mod_option_keyboard = { "keyboard", chosen, page, 0 };
