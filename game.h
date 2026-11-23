/* game.h - the contract between the two halves of milestone 12 (the app: exe check, save folder, Steam search).
 *   game.c  : loads the exe, runs the game, turns every graphics call of the game into one host_* call
 *   main.m  : window, keyboard, and the host_* functions implemented with Metal
 * Ids are small integers handed out by the host (0, 1, 2, ...). notes/gfx_contract.md explains each call.
 */
#ifndef GAME_H
#define GAME_H
#include <stdint.h>

/* ---- the window half calls these ---- */
int  game_exe_supported(const char *exe_path);          /* 1 = this is the exe version the loader was made for.
                                                           Every address in the loader belongs to that one build;
                                                           any other file must be refused. */
void game_start(const char *exe_path, const char *sav_path, int window_width, int window_height);
void game_frame(void);                          /* one frame: the game issues all host_* calls inside it */
void game_set_key(int windows_vk, int down);
void game_set_pad(int connected, int type, unsigned buttons, float stick_x, float stick_y);
        /* call once per frame before game_frame. type: 0 PlayStation, 1 Xbox, 2 Nintendo (which button pictures
           the game shows). buttons: XInput bits - d-pad up 1, down 2, left 4, right 8, start 0x10, back 0x20,
           left stick click 0x40, right stick click 0x80, left shoulder 0x100, right shoulder 0x200,
           A 0x1000, B 0x2000, X 0x4000, Y 0x8000. Stick: -1..1, up and right are positive. */
void game_set_window_size(int width, int height);       /* size of the back buffer in pixels, whenever it changes */
int  game_wants_fullscreen(void);                       /* the game's own "fullscreen" option */
int  game_wants_quit(void);
void game_lock_save(void);                              /* from now on the game no longer writes the save file: for when
                                                           the file was replaced under the running game (a Steam Cloud
                                                           download), which still has the old save in memory */
int  game_steam_start(const char *libsteam_api_path);   /* optional, before game_start: 1 = connected and
                                                           achievements available, 0 = not (try another copy) */
void game_steam_stop(void);                             /* when the program ends */                             /* set when "quit" is chosen in the main menu */
const char *game_shader_source(void);           /* after game_start: Metal source of vs_main and ps00, ps01, ...
                                                   translated from the shaders inside the exe */
extern const uint8_t *game_fullscreen_quad;     /* 6 vertices (192 bytes) for host_draw_fullscreen */
void game_audio_mix(float *out, int frames);    /* fill `frames` stereo frames (left, right floats, 48000 Hz);
                                                   may be called from the audio thread */

/* ---- the game half calls these; the window half implements them ---- */
/* creating things (during game_start) */
int  host_texture_create(const void *rgba, int width, int height);
void host_texture_update(int texture, const void *rgba, int width, int height);
int  host_target_create(const char *name, int format, int width, int height, const float clear_color[4]);
        /* format: 0 RGBA8, 1 R16 float, 2 RG16 float, 3 R32 float, 4 RGBA16 float */
int  host_blend_create(int enable, int src, int src_alpha, int op, int op_alpha, int dst, int dst_alpha,
                       int write_mask);
        /* factors: 0 zero, 1 one, 2 src colour, 3 1-src colour, 4 dst colour, 5 1-dst colour, 6 src alpha,
           7 1-src alpha, 8 dst alpha, 9 1-dst alpha, 10 src alpha saturated
           op: 0 add, 1 subtract, 2 reverse subtract, 3 min, 4 max      write_mask: 1 R, 2 G, 4 B, 8 A */
int  host_pipeline_create(int pixel_shader, int blend, int target_format);     /* pixel_shader 7 = function "ps07" in game_shader_source() */
int  host_cbuffer_create(int size);
void host_cbuffer_update(int cbuffer, const void *data, int size);

/* per frame, in the order the game issues them */
void *host_vertex_memory(void);                 /* where the game writes this frame's vertices (32 bytes each) */
void host_set_target(int target);               /* -1 = the window's back buffer */
void host_clear_target(int target);             /* -1 = back buffer; clears to the target's clear colour */
void host_set_pipeline(int pipeline);
void host_set_topology(int lines);              /* 0 = triangle list, 1 = line list */
void host_bind_texture(int slot, int is_target, int index);    /* slot 0..9; a texture or a render target */
void host_bind_cbuffer(int slot, int cbuffer);                  /* slot 0..3 */
void host_set_viewport(float x, float y, float width, float height);    /* also the scissor rectangle */
void host_draw(int first_vertex, int vertex_count, unsigned texture_slots_read);
void host_draw_fullscreen(unsigned texture_slots_read);
        /* texture_slots_read: bit n set = the current pixel shader reads texture slot n */

#endif
