/* ui.c - see ui.h. */
#include <string.h>
#include "ui.h"
#include "mods.h"
#include "game_api.h"

/* The game's two fixed fonts (0 small, 1 large) are tables of 16-bit numbers in its state: for each of 256
 * characters x, y, width, height of its picture, then the height of a line and the gap between characters.
 * (draw_text_centered reads the same table.) */
#define FONT(font)  ((int16_t *)(GAME + 0x3e5b00 + (font) * 0x804))
enum { FONT_LINE = 0x400, FONT_GAP = 0x401 };

static int char_width(int font, char c) { return FONT(font)[(uint8_t)c * 4 + 2] + FONT(font)[FONT_GAP]; }

/* The fixed fonts have letters, digits and . , : / - ' ! ? but no ( ) * _ @ " and other signs. Text that comes
 * from elsewhere (Steam's error messages) is made showable: a sign without a picture becomes a similar one. */
static char showable(char c) {
    if (c == ' ' || c == '\n' || FONT(0)[(uint8_t)c * 4 + 2] > 0) return c;
    return c == '(' || c == '[' || c == '_' ? '-' : c == '"' || c == '`' ? '\'' : ' ';
}

/* plain letters -> the game's 16-bit characters */
static const uint16_t *text16(const char *text) {
    static uint16_t wide[1024];
    size_t i;
    for (i = 0; text[i] && i < 1023; i++) wide[i] = (uint8_t)text[i];
    wide[i] = 0;
    return wide;
}

void ui_title(const char *text) {
    set_color(UI_WHITE);
    push_layer(0xe);
    set_font(1);
    draw_text_centered(160, 16, text16(text));
    set_font(0);
    pop_layer();
}

/* Break `text` into lines of at most max_width pixels in the small font: the result has a '\n' wherever a line
 * ends. Returns the number of lines; *widest = the width of the longest one. */
static int wrap(const char *text, int max_width, char *lines, size_t size, int *widest) {
    size_t out = 0, line_start = 0, last_space = 0;
    int width = 0, width_at_space = 0, count = 1;
    *widest = 0;
    for (size_t i = 0; text[i] && out < size - 1; i++) {
        char c = showable(text[i]);
        if (c == '\n') { lines[out++] = c; line_start = out; last_space = 0; width = 0; count++; continue; }
        if (c == ' ') { last_space = out; width_at_space = width; }
        lines[out++] = c;
        width += char_width(0, c);
        if (width > max_width && last_space > line_start) {     /* too long: the last space becomes the line break */
            lines[last_space] = '\n';
            if (width_at_space > *widest) *widest = width_at_space;
            line_start = last_space + 1;
            width -= width_at_space + char_width(0, ' ');
            last_space = 0;
            count++;
        }
        if (width > *widest) *widest = width;
    }
    lines[out] = 0;
    return count;
}

int ui_text(int center_x, int y, int max_width, uint32_t color, const char *text) {
    char lines[1024];
    int widest, count = wrap(text, max_width, lines, sizeof lines, &widest);
    set_font(0);
    set_color(color);
    draw_text_centered(center_x, y, text16(lines));
    set_color(UI_WHITE);
    return y + count * FONT(0)[FONT_LINE];
}

void ui_text_size(const char *text, int max_width, int *width, int *height) {
    char lines[1024];
    int count = wrap(text, max_width, lines, sizeof lines, width);
    *height = count * FONT(0)[FONT_LINE];
}

/* The game only draws centred text, so each line is drawn by itself, centred around its own middle. */
int ui_text_left(int x, int y, int max_width, uint32_t color, const char *text) {
    char lines[1024];
    int widest;
    wrap(text, max_width, lines, sizeof lines, &widest);
    set_font(0);
    set_color(color);
    for (char *line = lines; line; ) {
        char *end = strchr(line, '\n');
        if (end) *end = 0;
        int width = 0;
        for (const char *c = line; *c; c++) width += char_width(0, *c);
        if (width > 0) width -= FONT(0)[FONT_GAP];             /* no gap behind the last character */
        draw_text_centered(x + (width + 1) / 2, y, text16(line));
        y += FONT(0)[FONT_LINE];
        line = end ? end + 1 : NULL;
    }
    set_color(UI_WHITE);
    return y;
}

int ui_options(int y, const char *const *labels, int count) {
    int row = GAME_INT(MENU_ROW);
    if (menu_down_repeat() && row < count - 1) row++;
    if (menu_up_repeat() && row > 0) row--;
    if (row < 0 || row >= count) row = 0;
    GAME_INT(MENU_ROW) = row;

    /* the arrows: sprite 0x86, 8 frames, a new one every 4 game frames - as in the main menu */
    int line = *(int16_t *)(current_lang_font() + 0x2000e), arrow = (int)(GAME_INT64(TOTAL_FRAMES) / 4 % 8);
    set_color(UI_WHITE);
    for (int i = 0; i < count; i++) {
        const uint16_t *label = text16(labels[i]);
        int width = text_width(label), x = 160 - width / 2;
        if (i == row) {
            draw_atlas_scaled(x - 10, y + 2, 8, 8, 0x86, arrow);
            draw_atlas_scaled(x + width + 10, y + 2, -8, 8, 0x86, arrow);
        }
        draw_text(x, y, label);
        y += line;
    }
    return count > 0 && input_confirm_pressed() ? row : -1;
}

void ui_rect(int x, int y, int width, int height, uint32_t color) {
    push_color(color);
    draw_rect(x, y, width, height);
    pop_color();
}

/* ---- typing ---- */
static ui_field *active_field;

void ui_field_begin(ui_field *field, int secret) {
    memset(field, 0, sizeof *field);
    field->secret = secret;
    active_field = field;
}
void ui_field_end(void) { active_field = 0; }

int ui_line(int y, uint32_t color, const char *text) {
    const uint16_t *wide = text16(text);
    set_color(color);
    draw_text(160 - text_width(wide) / 2, y, wide);
    set_color(UI_WHITE);
    return y + *(int16_t *)(current_lang_font() + 0x2000e);
}

int ui_field_draw(int y, const ui_field *field) {
    char shown[sizeof field->text + 2];
    size_t length = strlen(field->text);
    if (field->secret) memset(shown, '*', length);
    else memcpy(shown, field->text, length);
    shown[length] = GAME_INT64(TOTAL_FRAMES) / 30 % 2 ? '_' : ' ';      /* a blinking cursor */
    shown[length + 1] = 0;
    return ui_line(y, UI_WHITE, shown);
}

int mods_wants_typing(void) { return active_field != 0; }

void mods_typed(int key, const char *text) {
    ui_field *field = active_field;
    if (!field || field->done) return;
    size_t length = strlen(field->text);
    if (key == MODS_KEY_RETURN) field->done = 1;
    else if (key == MODS_KEY_ESCAPE) field->done = -1;
    else if (key == MODS_KEY_BACKSPACE) { if (length) field->text[length - 1] = 0; }
    else if (text) {
        for (; *text; text++)                                           /* plain visible characters only */
            if (*text >= 0x20 && *text < 0x7f && length < sizeof field->text - 1) field->text[length++] = *text;
        field->text[length] = 0;
    }
}
