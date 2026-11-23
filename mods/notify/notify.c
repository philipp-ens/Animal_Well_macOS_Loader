/* notify.c - see notify.h.
 *
 * To draw in every game mode the notifications need a place in the game's code that runs once per frame while
 * drawing is possible. That place is where game_update calls render_frame (rva 0x61bd7): everything the game
 * drew in this frame is in its lists by then, and render_frame puts those lists on the screen. The call is
 * pointed at a small stub that first calls draw_notifications and then goes on to render_frame. The stub keeps
 * render_frame's arguments (rcx, rdx, r8, r9, xmm0-xmm3) intact around our call. */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "notify.h"
#include "../ui.h"
#include "../game_api.h"

enum { MAX_NOTES = 4, FRAMES_PER_SECOND = 60, LEFT = 4, TOP = 4, TEXT_WIDTH = 150 };

typedef struct { char text[200]; uint32_t color; int frames_left; } note;
static note notes[MAX_NOTES];                   /* the oldest first; frames_left 0 = unused */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

void notify_for(const char *text, uint32_t color, int seconds) {
    pthread_mutex_lock(&lock);
    int count = 0;
    while (count < MAX_NOTES && notes[count].frames_left > 0) count++;
    if (count == MAX_NOTES) {                   /* full: the oldest goes */
        memmove(notes, notes + 1, sizeof notes - sizeof *notes);
        count--;
    }
    snprintf(notes[count].text, sizeof notes[count].text, "%s", text);
    notes[count].color = color;
    notes[count].frames_left = seconds * FRAMES_PER_SECOND;
    pthread_mutex_unlock(&lock);
    printf("notification: %s\n", text);
}

void notify(const char *text, uint32_t color) { notify_for(text, color, 5); }

/* once per frame, right before the game puts the frame on the screen */
static void MSABI draw_notifications(void) {
    note shown[MAX_NOTES];
    int count = 0;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_NOTES; i++) {       /* one frame less for each; those that ran out are dropped */
        if (notes[i].frames_left <= 0) continue;
        notes[i].frames_left--;
        if (notes[i].frames_left > 0) shown[count++] = notes[i];
    }
    memcpy(notes, shown, (size_t)count * sizeof *notes);
    memset(notes + count, 0, (size_t)(MAX_NOTES - count) * sizeof *notes);
    pthread_mutex_unlock(&lock);
    if (!count) return;

    push_layer(0x29);                           /* the layer of the menus' texts: above the game's picture */
    int y = TOP;
    for (int i = 0; i < count; i++) {
        int width, height;
        ui_text_size(shown[i].text, TEXT_WIDTH, &width, &height);
        ui_rect(LEFT, y, width + 9, height + 4, 0xc8000000);       /* a dark, slightly see-through box */
        ui_rect(LEFT, y, 2, height + 4, shown[i].color);            /* the coloured bar */
        ui_text_left(LEFT + 5, y + 2, TEXT_WIDTH, shown[i].color, shown[i].text);
        y += height + 6;
    }
    pop_layer();
}

extern const uint8_t mod_notify_stub[], mod_notify_stub_slots[], mod_notify_stub_end[];
__asm__(
    ".intel_syntax noprefix\n"
    ".text\n"
    "_mod_notify_stub:\n"                       /* reached by game_update's "call render_frame" */
    "    push rcx\n"
    "    push rdx\n"
    "    push r8\n"
    "    push r9\n"
    "    sub rsp, 0x68\n"                       /* room for xmm0-xmm3, and the stack is aligned for a call */
    "    movups [rsp + 0x20], xmm0\n"
    "    movups [rsp + 0x30], xmm1\n"
    "    movups [rsp + 0x40], xmm2\n"
    "    movups [rsp + 0x50], xmm3\n"
    "    call qword ptr [rip + _mod_notify_stub_slots]\n"
    "    movups xmm0, [rsp + 0x20]\n"
    "    movups xmm1, [rsp + 0x30]\n"
    "    movups xmm2, [rsp + 0x40]\n"
    "    movups xmm3, [rsp + 0x50]\n"
    "    add rsp, 0x68\n"
    "    pop r9\n"
    "    pop r8\n"
    "    pop rdx\n"
    "    pop rcx\n"
    "    jmp qword ptr [rip + _mod_notify_stub_slots + 8]\n"
    "_mod_notify_stub_slots:\n"
    "    .quad 0, 0\n"                          /* draw_notifications, render_frame */
    "_mod_notify_stub_end:\n"
    ".att_syntax\n");

void notify_install(void) {
    const uint32_t call = 0x61bd7, render_frame = 0x104830;
    int32_t distance;
    memcpy(&distance, AT(call + 1), 4);
    uint32_t stub = mods_add_code(mod_notify_stub, (size_t)(mod_notify_stub_end - mod_notify_stub));
    if (*AT(call) != 0xE8 || call + 5 + (uint32_t)distance != render_frame || !stub) {
        fprintf(stderr, "notify_install: not applied\n");
        return;
    }
    uint64_t slots[2] = { (uint64_t)(uintptr_t)draw_notifications, (uint64_t)(uintptr_t)AT(render_frame) };
    memcpy(AT(stub + (uint32_t)(mod_notify_stub_slots - mod_notify_stub)), slots, sizeof slots);
    distance = (int32_t)(stub - (call + 5));
    memcpy(AT(call + 1), &distance, 4);         /* "call stub" */
}
