/* notify.c - see notify.h. notify_draw is called once per frame by the frame hook in mods.c, right before the
 * game puts the frame on the screen. */
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

void notify_draw(void) {
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
