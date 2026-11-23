/* Started without arguments (double-click) it finds everything itself - if it knows no
 * Animal Well.exe it shows a dialog (choose a file / download with SteamCMD / download with the Steam app's
 * console), checks that the file is the supported version, keeps the save in
 * ~/Library/Application Support/Animal Well/, and looks for Valve's libsteam_api.dylib among your
 * installed Steam games. With arguments it behaves like milestone 11 (for testing from the terminal).
 * Started by double-click, everything the loader prints goes to loader.log in that same folder, and the window
 * title says whether Steam is connected. The Steam overlay is loaded too (restart_with_overlay).
 * From 11: give the path of a libsteam_api.dylib as third argument (Steam running and logged in) and the
 * game's achievements go to Steam. Without it nothing changes.
 * From 10: no aw_shaders.metal any more - compile_shaders() takes the Metal source that the game half made
 * from the shaders inside the exe (dxbc2msl.c).
 * From 9: read_gamepad() (any controller macOS knows), the window can be resized or made fullscreen (the
 * picture is always a whole multiple of 320 x 180, centred), the game's fullscreen option and its "quit" work.
 * From 8: start_audio() opens the Mac's sound output and keeps asking the game half for the next piece of mixed
 * sound (game_audio_mix). The save file given on the command line is now read AND written by the game.
 *
 * game.c turns every graphics call of the game into one host_* call (see game.h). This file implements
 * them: 24 render targets, 51 pipelines built from the game's own (translated) shaders, 8 blend states, constant
 * buffers, textures. notes/gfx_contract.md is the specification.
 *
 * Keys: arrows or WASD move, Space = jump / confirm, Q or Z or Return = second button, E or X = use item,
 *       Esc or P = pause. Close the window or press Cmd+Q to quit.
 *
 */
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreImage/CoreImage.h>
#import <AudioToolbox/AudioToolbox.h>
#import <GameController/GameController.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include "game.h"
#include "steamcloud.h"

#define WINDOW_W 1280
#define WINDOW_H 720

/* ------------------------------------------------------------------ everything the game created */
static id<MTLDevice> g_device;
static id<MTLCommandQueue> g_queue;
static id<MTLLibrary> g_library;                        /* the game's shaders, compiled at start */
static id<MTLFunction> g_vertexFunction;
static MTLVertexDescriptor *g_vertexLayout;
static id<MTLSamplerState> g_pointSampler, g_bilinearSampler;
static id<MTLBuffer> g_vertexBuffer, g_quadBuffer, g_zeroBuffer;
static id<MTLTexture> g_dummyTexture;

static NSMutableArray<id<MTLTexture>> *g_textures;
static NSMutableArray<id<MTLTexture>> *g_targetTextures;
static NSMutableArray<id<MTLBuffer>> *g_cbuffers;
static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *g_pipelineStates;

typedef struct { float clear[4]; int format, width, height; } target_info;
typedef struct { int enable, src, src_alpha, op, op_alpha, dst, dst_alpha, write_mask; } blend_info;
typedef struct { int pixel_shader, blend, format; } pipeline_info;
static target_info g_targets[64];
static blend_info g_blends[32];
static pipeline_info g_pipelines[128];
static int g_targetCount, g_blendCount, g_pipelineCount;

/* ------------------------------------------------------------------ the state of the current frame */
static id<MTLCommandBuffer> g_commands;                 /* nil outside a frame */
static id<MTLRenderCommandEncoder> g_encoder;           /* open render pass, or nil */
static id<CAMetalDrawable> g_drawable;
static int g_target = -2;                               /* -1 back buffer, -2 nothing yet */
static int g_pipeline = -1, g_lines;
static int g_boundCbuffer[4] = { -1, -1, -1, -1 };
static int g_boundTexture[10], g_boundIsTarget[10];
static float g_viewport[4];
static BOOL g_initialClearDone;

static MTLPixelFormat pixel_format(int format) {
    switch (format) {
    case 1:  return MTLPixelFormatR16Float;
    case 2:  return MTLPixelFormatRG16Float;
    case 3:  return MTLPixelFormatR32Float;
    case 4:  return MTLPixelFormatRGBA16Float;
    default: return MTLPixelFormatRGBA8Unorm;
    }
}

/* ------------------------------------------------------------------ creating things */
void host_texture_update(int texture, const void *rgba, int width, int height) {
    if (texture < 0 || texture >= (int)g_textures.count || !rgba || width <= 0 || height <= 0) return;
    id<MTLTexture> tex = g_textures[texture];
    if ((int)tex.width != width || (int)tex.height != height) {         /* size changed: make a new one */
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:(NSUInteger)width
                                                              height:(NSUInteger)height
                                                           mipmapped:NO];
        tex = [g_device newTextureWithDescriptor:desc];
        g_textures[texture] = tex;
    }
    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
           mipmapLevel:0
             withBytes:rgba
           bytesPerRow:(NSUInteger)width * 4];
}

int host_texture_create(const void *rgba, int width, int height) {
    if (width <= 0 || height <= 0) { width = 1; height = 1; rgba = NULL; }
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:(NSUInteger)width
                                                          height:(NSUInteger)height
                                                       mipmapped:NO];
    [g_textures addObject:[g_device newTextureWithDescriptor:desc]];
    int index = (int)g_textures.count - 1;
    host_texture_update(index, rgba, width, height);
    return index;
}

int host_target_create(const char *name, int format, int width, int height, const float clear_color[4]) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format(format)
                                                           width:(NSUInteger)width
                                                          height:(NSUInteger)height
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> tex = [g_device newTextureWithDescriptor:desc];
    tex.label = [NSString stringWithUTF8String:name];
    [g_targetTextures addObject:tex];
    target_info *info = &g_targets[g_targetCount];
    info->format = format; info->width = width; info->height = height;
    for (int i = 0; i < 4; i++) info->clear[i] = clear_color ? clear_color[i] : 0.0f;
    return g_targetCount++;
}

int host_blend_create(int enable, int src, int src_alpha, int op, int op_alpha, int dst, int dst_alpha,
                      int write_mask) {
    blend_info info = { enable, src, src_alpha, op, op_alpha, dst, dst_alpha, write_mask };
    g_blends[g_blendCount] = info;
    return g_blendCount++;
}

int host_pipeline_create(int pixel_shader, int blend, int target_format) {
    pipeline_info info = { pixel_shader, blend, target_format };
    g_pipelines[g_pipelineCount] = info;
    return g_pipelineCount++;
}

int host_cbuffer_create(int size) {
    NSUInteger length = size < 256 ? 256 : (NSUInteger)size;
    [g_cbuffers addObject:[g_device newBufferWithLength:length options:MTLResourceStorageModeShared]];
    return (int)g_cbuffers.count - 1;
}

void host_cbuffer_update(int cbuffer, const void *data, int size) {
    if (cbuffer < 0 || cbuffer >= (int)g_cbuffers.count || !data || size <= 0) return;
    id<MTLBuffer> buffer = g_cbuffers[cbuffer];
    if ((NSUInteger)size > buffer.length) size = (int)buffer.length;
    memcpy(buffer.contents, data, (size_t)size);
}

void *host_vertex_memory(void) { return g_vertexBuffer.contents; }

/* ------------------------------------------------------------------ blend state + pipeline for Metal */
static MTLBlendFactor blend_factor(int f) {
    switch (f) {
    case 0:  return MTLBlendFactorZero;
    case 1:  return MTLBlendFactorOne;
    case 2:  return MTLBlendFactorSourceColor;
    case 3:  return MTLBlendFactorOneMinusSourceColor;
    case 4:  return MTLBlendFactorDestinationColor;
    case 5:  return MTLBlendFactorOneMinusDestinationColor;
    case 6:  return MTLBlendFactorSourceAlpha;
    case 7:  return MTLBlendFactorOneMinusSourceAlpha;
    case 8:  return MTLBlendFactorDestinationAlpha;
    case 9:  return MTLBlendFactorOneMinusDestinationAlpha;
    case 10: return MTLBlendFactorSourceAlphaSaturated;
    default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blend_operation(int op) {
    switch (op) {
    case 1:  return MTLBlendOperationSubtract;          /* source - destination */
    case 2:  return MTLBlendOperationReverseSubtract;
    case 3:  return MTLBlendOperationMin;
    case 4:  return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

/* A game pipeline = pixel shader + blend state. Metal also wants to know the pixel format it draws into, and
 * the window's back buffer has a different one (BGRA) than the game's targets - so states are made on demand,
 * one per (pipeline, format) pair, and remembered. */
static id<MTLRenderPipelineState> pipeline_state(int pipeline, MTLPixelFormat format) {
    NSNumber *key = @(((long)pipeline << 16) | (long)format);
    id<MTLRenderPipelineState> state = g_pipelineStates[key];
    if (state) return state;

    pipeline_info info = g_pipelines[pipeline];
    blend_info blend = g_blends[info.blend];
    NSString *name = [NSString stringWithFormat:@"ps%02d", info.pixel_shader];
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = name;
    desc.vertexFunction = g_vertexFunction;
    desc.fragmentFunction = [g_library newFunctionWithName:name];
    desc.vertexDescriptor = g_vertexLayout;
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = format;
    color.blendingEnabled = blend.enable != 0;
    color.sourceRGBBlendFactor = blend_factor(blend.src);
    color.destinationRGBBlendFactor = blend_factor(blend.dst);
    color.rgbBlendOperation = blend_operation(blend.op);
    color.sourceAlphaBlendFactor = blend_factor(blend.src_alpha);
    color.destinationAlphaBlendFactor = blend_factor(blend.dst_alpha);
    color.alphaBlendOperation = blend_operation(blend.op_alpha);
    MTLColorWriteMask mask = MTLColorWriteMaskNone;
    if (blend.write_mask & 1) mask |= MTLColorWriteMaskRed;
    if (blend.write_mask & 2) mask |= MTLColorWriteMaskGreen;
    if (blend.write_mask & 4) mask |= MTLColorWriteMaskBlue;
    if (blend.write_mask & 8) mask |= MTLColorWriteMaskAlpha;
    color.writeMask = mask;

    NSError *error = nil;
    state = [g_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!state) { NSLog(@"cannot create pipeline %d (%@): %@", pipeline, name, error); exit(1); }
    g_pipelineStates[key] = state;
    return state;
}

/* ------------------------------------------------------------------ render passes */
static id<MTLTexture> target_texture(int target) {
    if (target == -1) return g_drawable.texture;        /* the window */
    if (target < 0 || target >= (int)g_targetTextures.count) return nil;
    return g_targetTextures[target];
}

static void end_pass(void) {
    if (g_encoder) { [g_encoder endEncoding]; g_encoder = nil; }
}

/* Metal draws inside "render passes", one per target. A pass is opened lazily at the first draw into the
 * current target and closed when the game switches target. */
static BOOL begin_pass(void) {
    if (g_encoder) return YES;
    if (!g_commands) return NO;
    id<MTLTexture> tex = target_texture(g_target);
    if (!tex) return NO;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = tex;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;        /* keep what is already there */
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    g_encoder = [g_commands renderCommandEncoderWithDescriptor:pass];

    /* viewport and scissor box: the game's current one, kept inside the target */
    double tw = (double)tex.width, th = (double)tex.height;
    double x = g_viewport[0], y = g_viewport[1], w = g_viewport[2], h = g_viewport[3];
    if (w <= 0 || h <= 0) { x = 0; y = 0; w = tw; h = th; }
    MTLViewport viewport = { x, y, w, h, 0.0, 1.0 };
    [g_encoder setViewport:viewport];
    double x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    double x1 = x + w > tw ? tw : x + w, y1 = y + h > th ? th : y + h;
    if (x1 > x0 && y1 > y0) {
        MTLScissorRect box = { (NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0) };
        [g_encoder setScissorRect:box];
    }
    return YES;
}

static void clear_now(int target) {
    id<MTLTexture> tex = target_texture(target);
    if (!tex || !g_commands) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = tex;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (target >= 0) {
        const float *c = g_targets[target].clear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]);
    } else {
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    }
    [[g_commands renderCommandEncoderWithDescriptor:pass] endEncoding];     /* a pass that only clears */
}

void host_set_target(int target) {
    if (target == g_target) return;
    end_pass();
    g_target = target;
}

void host_clear_target(int target) {
    end_pass();             /* Metal allows only one open pass per command buffer, whatever target it draws into */
    clear_now(target);
}

void host_set_pipeline(int pipeline) { g_pipeline = pipeline; }
void host_set_topology(int lines) { g_lines = lines; }

void host_bind_texture(int slot, int is_target, int index) {
    if (slot < 0 || slot > 9) return;
    g_boundIsTarget[slot] = is_target;
    g_boundTexture[slot] = index + 1;                   /* 0 = nothing bound */
}

void host_bind_cbuffer(int slot, int cbuffer) {
    if (slot >= 0 && slot < 4) g_boundCbuffer[slot] = cbuffer;
}

void host_set_viewport(float x, float y, float width, float height) {
    if (x == g_viewport[0] && y == g_viewport[1] && width == g_viewport[2] && height == g_viewport[3]) return;
    g_viewport[0] = x; g_viewport[1] = y; g_viewport[2] = width; g_viewport[3] = height;
    end_pass();                                         /* the next pass picks the new box up */
}

static void draw(id<MTLBuffer> vertices, int first, int count, unsigned texture_slots_read) {
    if (g_pipeline < 0 || count <= 0 || !begin_pass()) return;
    id<MTLTexture> into = target_texture(g_target);
    [g_encoder setRenderPipelineState:pipeline_state(g_pipeline, into.pixelFormat)];
    [g_encoder setVertexBuffer:vertices offset:0 atIndex:0];

    /* constant buffers: slots 0-3 for the pixel shader; the vertex shader reads slots 2 and 3 */
    for (int slot = 0; slot < 4; slot++) {
        int cb = g_boundCbuffer[slot];
        id<MTLBuffer> buffer = (cb >= 0 && cb < (int)g_cbuffers.count) ? g_cbuffers[cb] : g_zeroBuffer;
        [g_encoder setFragmentBuffer:buffer offset:0 atIndex:(NSUInteger)slot];
        if (slot >= 2) [g_encoder setVertexBuffer:buffer offset:0 atIndex:(NSUInteger)slot];
    }
    /* textures: only the slots this pixel shader reads (a target must never be read while it is drawn into) */
    for (int slot = 0; slot < 10; slot++) {
        if (!(texture_slots_read & (1u << slot))) continue;
        id<MTLTexture> tex = g_dummyTexture;
        int index = g_boundTexture[slot] - 1;
        if (index >= 0) {
            if (g_boundIsTarget[slot]) {
                if (index < (int)g_targetTextures.count && index != g_target) tex = g_targetTextures[index];
            } else if (index < (int)g_textures.count) {
                tex = g_textures[index];
            }
        }
        [g_encoder setFragmentTexture:tex atIndex:(NSUInteger)slot];
    }
    [g_encoder setFragmentSamplerState:g_pointSampler atIndex:0];
    [g_encoder setFragmentSamplerState:g_bilinearSampler atIndex:1];
    [g_encoder drawPrimitives:g_lines ? MTLPrimitiveTypeLine : MTLPrimitiveTypeTriangle
                  vertexStart:(NSUInteger)first
                  vertexCount:(NSUInteger)count];
}

void host_draw(int first_vertex, int vertex_count, unsigned texture_slots_read) {
    draw(g_vertexBuffer, first_vertex, vertex_count, texture_slots_read);
}

void host_draw_fullscreen(unsigned texture_slots_read) {
    int lines = g_lines;
    g_lines = 0;
    draw(g_quadBuffer, 0, 6, texture_slots_read);
    g_lines = lines;
}

/* ------------------------------------------------------------------ keyboard: Mac key codes -> Windows codes */
static int windows_key(unsigned short mac_key_code) {
    switch (mac_key_code) {
    /* letters, by position on an American keyboard (fallback only) */
    case 0x00: return 'A';  case 0x0B: return 'B';  case 0x08: return 'C';  case 0x02: return 'D';
    case 0x0E: return 'E';  case 0x03: return 'F';  case 0x05: return 'G';  case 0x04: return 'H';
    case 0x22: return 'I';  case 0x26: return 'J';  case 0x28: return 'K';  case 0x25: return 'L';
    case 0x2E: return 'M';  case 0x2D: return 'N';  case 0x1F: return 'O';  case 0x23: return 'P';
    case 0x0C: return 'Q';  case 0x0F: return 'R';  case 0x01: return 'S';  case 0x11: return 'T';
    case 0x20: return 'U';  case 0x09: return 'V';  case 0x0D: return 'W';  case 0x07: return 'X';
    case 0x10: return 'Y';  case 0x06: return 'Z';
    /* the digit row (by position: on some layouts these keys type digits only with Shift) */
    case 0x12: return '1';  case 0x13: return '2';  case 0x14: return '3';  case 0x15: return '4';
    case 0x17: return '5';  case 0x16: return '6';  case 0x1A: return '7';  case 0x1C: return '8';
    case 0x19: return '9';  case 0x1D: return '0';
    /* the number pad: Windows 0x60 (0) ... 0x69 (9) */
    case 0x52: return 0x60; case 0x53: return 0x61; case 0x54: return 0x62; case 0x55: return 0x63;
    case 0x56: return 0x64; case 0x57: return 0x65; case 0x58: return 0x66; case 0x59: return 0x67;
    case 0x5B: return 0x68; case 0x5C: return 0x69;
    case 0x43: return 0x6A;     /* pad *      */
    case 0x45: return 0x6B;     /* pad +      */
    case 0x4E: return 0x6D;     /* pad -      */
    case 0x41: return 0x6E;     /* pad .      */
    case 0x4B: return 0x6F;     /* pad /      */
    case 0x4C: return 0x0D;     /* pad enter  */
    /* arrows and the keys around them */
    case 0x7B: return 0x25;     /* left arrow */
    case 0x7C: return 0x27;     /* right arrow */
    case 0x7D: return 0x28;     /* down arrow */
    case 0x7E: return 0x26;     /* up arrow */
    case 0x73: return 0x24;     /* home */
    case 0x77: return 0x23;     /* end */
    case 0x74: return 0x21;     /* page up */
    case 0x79: return 0x22;     /* page down */
    case 0x75: return 0x2E;     /* forward delete */
    /* the big keys */
    case 0x31: return 0x20;     /* space */
    case 0x24: return 0x0D;     /* return */
    case 0x35: return 0x1B;     /* escape */
    case 0x30: return 0x09;     /* tab */
    case 0x33: return 0x08;     /* delete (backspace) */
    /* punctuation, by position on an American keyboard */
    case 0x29: return 0xBA;     /* ;  */
    case 0x18: return 0xBB;     /* =  */
    case 0x2B: return 0xBC;     /* ,  */
    case 0x1B: return 0xBD;     /* -  */
    case 0x2F: return 0xBE;     /* .  */
    case 0x2C: return 0xBF;     /* /  */
    case 0x32: return 0xC0;     /* `  */
    case 0x21: return 0xDB;     /* [  */
    case 0x2A: return 0xDC;     /* \  */
    case 0x1E: return 0xDD;     /* ]  */
    case 0x27: return 0xDE;     /* '  */
    /* F1 ... F12: Windows 0x70 ... 0x7B */
    case 0x7A: return 0x70; case 0x78: return 0x71; case 0x63: return 0x72; case 0x76: return 0x73;
    case 0x60: return 0x74; case 0x61: return 0x75; case 0x62: return 0x76; case 0x64: return 0x77;
    case 0x65: return 0x78; case 0x6D: return 0x79; case 0x67: return 0x7A; case 0x6F: return 0x7B;
    default:   return -1;
    }
}

/* The Windows number for a key press: a letter key by the letter it types, everything else by its position. */
static int windows_key_for_event(NSEvent *event) {
    NSString *typed = event.charactersIgnoringModifiers;
    if (typed.length == 1) {
        unichar c = [typed characterAtIndex:0];
        if (c >= 'a' && c <= 'z') return c - 'a' + 'A';
        if (c >= 'A' && c <= 'Z') return c;
    }
    return windows_key(event.keyCode);
}

/* Which keys we have told the game are held: for each Mac key code, the Windows number that was reported
 * (0 = not held). The key-up must report the same number as the key-down did.
 * macOS does not always deliver the "key up": it gets lost when the window changes during the press - above all
 * during the fullscreen animation, which the game's own fullscreen option starts while the confirm key is still
 * down. The game would then see that key as held forever. So whenever the window changes state, every held key
 * is released. */
static int g_keyHeld[128];

static void release_all_keys(void) {
    for (int code = 0; code < 128; code++) {
        if (!g_keyHeld[code]) continue;
        game_set_key(g_keyHeld[code], 0);
        g_keyHeld[code] = 0;
    }
}

@interface GameView : MTKView
@end
@implementation GameView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat || event.keyCode >= 128) return;
    int key = windows_key_for_event(event);
    if (key <= 0) return;                                   /* a key the game has no number for */
    if (g_keyHeld[event.keyCode]) game_set_key(g_keyHeld[event.keyCode], 0);
    g_keyHeld[event.keyCode] = key;
    game_set_key(key, 1);
}
- (void)keyUp:(NSEvent *)event {
    if (event.keyCode >= 128 || !g_keyHeld[event.keyCode]) return;
    game_set_key(g_keyHeld[event.keyCode], 0);
    g_keyHeld[event.keyCode] = 0;
}
@end

/* ------------------------------------------------------------------ gamepad */
/* Asks macOS for the current controller and reports its state to the game half in the form the game expects
 * (the button bits of Windows' XInput). Called once per frame. */
static void read_gamepad(void) {
    GCController *controller = GCController.current;
    if (!controller) controller = GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) { game_set_pad(0, 1, 0, 0.0f, 0.0f); return; }

    unsigned buttons = 0;
    if (pad.dpad.up.isPressed)            buttons |= 0x0001;
    if (pad.dpad.down.isPressed)          buttons |= 0x0002;
    if (pad.dpad.left.isPressed)          buttons |= 0x0004;
    if (pad.dpad.right.isPressed)         buttons |= 0x0008;
    if (pad.buttonMenu.isPressed)         buttons |= 0x0010;    /* start */
    if (pad.buttonOptions.isPressed)      buttons |= 0x0020;    /* back / select */
    if (pad.leftThumbstickButton.isPressed)  buttons |= 0x0040;
    if (pad.rightThumbstickButton.isPressed) buttons |= 0x0080;
    if (pad.leftShoulder.isPressed)       buttons |= 0x0100;
    if (pad.rightShoulder.isPressed)      buttons |= 0x0200;
    if (pad.buttonA.isPressed)            buttons |= 0x1000;
    if (pad.buttonB.isPressed)            buttons |= 0x2000;
    if (pad.buttonX.isPressed)            buttons |= 0x4000;
    if (pad.buttonY.isPressed)            buttons |= 0x8000;

    /* which button pictures the game should show: 0 PlayStation, 1 Xbox, 2 Nintendo */
    int type = 1;
    NSString *kind = controller.productCategory ?: @"";
    if ([kind containsString:@"DualSense"] || [kind containsString:@"DualShock"]) type = 0;
    else if ([kind containsString:@"Switch"] || [kind containsString:@"Joy-Con"]) type = 2;

    game_set_pad(1, type, buttons, pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value);
}

/* ------------------------------------------------------------------ one frame */
@interface Renderer : NSObject <MTKViewDelegate>
@end
@implementation Renderer
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
}

- (void)drawInMTKView:(MTKView *)view {
    g_drawable = view.currentDrawable;
    g_commands = [g_queue commandBuffer];
    g_target = -2;
    if (!g_initialClearDone) {                          /* new targets hold random memory: clear them all once */
        for (int i = 0; i < g_targetCount; i++) clear_now(i);
        g_initialClearDone = YES;
    }

    game_set_window_size((int)view.drawableSize.width, (int)view.drawableSize.height);
    read_gamepad();
    game_frame();                                       /* the game issues all its host_* calls in here */

    end_pass();
    if (g_drawable) [g_commands presentDrawable:g_drawable];
    [g_commands commit];
    [g_commands waitUntilCompleted];                    /* simple and safe: the GPU is done before the next frame */
    if (g_commands.error) NSLog(@"GPU error: %@", g_commands.error);
    g_commands = nil;
    g_drawable = nil;

    /* follow the game's own options: fullscreen on / off, and "quit" from the main menu */
    static int lastWanted = 0;
    int wanted = game_wants_fullscreen();
    if (wanted != lastWanted) {
        lastWanted = wanted;
        BOOL isFullscreen = (view.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
        if ((wanted != 0) != isFullscreen) {
            release_all_keys();                         /* the key that chose the option is still down right now */
            [view.window toggleFullScreen:nil];
        }
    }
    if (game_wants_quit()) [NSApp terminate:nil];
}
@end

/* ------------------------------------------------------------------ sound output */
/* An "audio queue" plays buffers one after another. Whenever it has finished one, it calls audio_callback on its
 * own thread; we refill the buffer with the next piece of mixed sound and hand it back. */
#define AUDIO_FRAMES 512                                    /* per buffer: about 11 ms at 48000 Hz */
static AudioQueueRef g_audioQueue;

static void audio_callback(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    game_audio_mix((float *)buffer->mAudioData, AUDIO_FRAMES);
    buffer->mAudioDataByteSize = AUDIO_FRAMES * 2 * sizeof(float);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static void start_audio(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof format);
    format.mSampleRate = 48000;                             /* what game_audio_mix produces */
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = 2;                           /* stereo, interleaved left / right */
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = 8;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 8;
    OSStatus status = AudioQueueNewOutput(&format, audio_callback, NULL, NULL, NULL, 0, &g_audioQueue);
    if (status != noErr) { fprintf(stderr, "no sound: AudioQueueNewOutput failed (%d)\n", (int)status); return; }
    for (int i = 0; i < 3; i++) {                           /* three buffers in rotation */
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(g_audioQueue, AUDIO_FRAMES * 2 * sizeof(float), &buffer);
        if (status != noErr) { fprintf(stderr, "no sound: cannot allocate a buffer (%d)\n", (int)status); return; }
        audio_callback(NULL, g_audioQueue, buffer);
    }
    status = AudioQueueStart(g_audioQueue, NULL);
    if (status != noErr) fprintf(stderr, "no sound: AudioQueueStart failed (%d)\n", (int)status);
}

/* ------------------------------------------------------------------ start-up: game file, save folder, Steam */
static NSString *const kExeKey = @"ExePath";                /* remembered between starts (NSUserDefaults) */
static NSString *const kSteamKey = @"SteamLibraryPath";

static NSString *save_folder(void) {
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Animal Well"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return folder;
}

/* ---------------- first start: getting the game file ----------------
 * The loader needs the user's own "Animal Well.exe". If none is known, a dialog offers three ways:
 *   1. choose a file that is already on this Mac
 *   2. download it with SteamCMD, Valve's command-line tool (runs in a Terminal window; the Steam login is typed
 *      there, never into this app)
 *   3. download it with the Steam app's hidden console (the command is copied to the clipboard)
 * All three end the same way: a file that passes game_exe_supported(). */
#define DEPOT_COMMAND @"download_depot 813230 813231 8951799273146338346"     /* app, Windows depot, exact build */

static NSString *app_game_file(void) {
    return [save_folder() stringByAppendingPathComponent:@"Animal Well.exe"];
}

static BOOL usable(NSString *path) {
    return path && [[NSFileManager defaultManager] fileExistsAtPath:path] &&
           game_exe_supported(path.fileSystemRepresentation);
}

/* places where a download (or Steam itself) may have put the file */
static NSString *downloaded_game_file(void) {
    NSString *steam = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
    NSArray<NSString *> *places = @[
        app_game_file(),
        [steam stringByAppendingPathComponent:@"steamapps/content/app_813230/depot_813231/Animal Well.exe"],
        [steam stringByAppendingPathComponent:
            @"Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_813230/depot_813231/Animal Well.exe"],
        [steam stringByAppendingPathComponent:@"steamapps/common/Animal Well/Animal Well.exe"],
    ];
    for (NSString *path in places) if (usable(path)) return path;
    return nil;
}

/* Remember the game file. A file that a download left behind (take = YES) is MOVED into the app's own folder, so
 * that there is one copy only and Steam cleaning its download folder cannot remove it. A file inside a real
 * Steam installation of the game (steamapps/common) stays where it is - Steam manages that folder. */
/* What a download through the Steam app's console leaves behind: the folder steamapps/content/app_813230 in
 * Steam's data folder. It has to go once the game file was taken out of it - while it exists, Steam takes the
 * download for done and does not fetch the files again. (This is Steam's folder for console downloads, not an
 * installed game; installed games are in steamapps/common and are never touched.) */
static void remove_steam_download_folder(void) {
    NSString *steam = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
    for (NSString *relative in @[ @"steamapps/content/app_813230",
                                  @"Steam.AppBundle/Steam/Contents/MacOS/steamapps/content/app_813230" ])
        [[NSFileManager defaultManager] removeItemAtPath:[steam stringByAppendingPathComponent:relative] error:nil];
}

static NSString *adopt_game_file(NSString *path, BOOL take) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *mine = app_game_file();
    BOOL installed = [path containsString:@"/steamapps/common/"];
    if (take && !installed && ![path isEqualToString:mine]) {
        BOOL fromSteamDownload = [path containsString:@"/steamapps/content/"];
        [files removeItemAtPath:mine error:nil];
        if ([files moveItemAtPath:path toPath:mine error:nil]) {
            path = mine;
            if (fromSteamDownload) remove_steam_download_folder();
        }
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:path forKey:kExeKey];
    [defaults removeObjectForKey:@"AskForGameFile"];
    return path;
}

static NSModalResponse ask(NSString *title, NSString *text, NSArray<NSString *> *buttons) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = text;
    for (NSString *button in buttons) [alert addButtonWithTitle:button];
    return [alert runModal];                            /* 1000 = first button, 1001 = second, ... */
}

/* Shows a message and, while it is open, looks once a second whether the game file has turned up. Returns the
 * file's path as soon as it has (the message closes by itself), or nil when the user pressed a button.
 * `stopped` (optional) is asked once a second too: when it says YES the message closes as well, and *did_stop
 * is set - used to notice that the download has ended without producing the file. */
static NSString *wait_for_game_file(NSString *title, NSString *text, NSArray<NSString *> *buttons,
                                    NSModalResponse *pressed, BOOL (^stopped)(void), BOOL *did_stop) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = text;
    for (NSString *button in buttons) [alert addButtonWithTitle:button];
    __block NSString *found = nil;
    __block BOOL ended = NO;
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        found = downloaded_game_file();
        if (!found && stopped && stopped()) ended = YES;
        if (found || ended) [NSApp abortModal];
    }];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    NSModalResponse response = [alert runModal];
    [timer invalidate];
    [alert.window orderOut:nil];
    if (pressed) *pressed = response;
    if (did_stop) *did_stop = ended;
    return found;
}

/* way 1: a file that is already here */
static NSString *choose_game_file(void) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = @"Choose your own copy of \"Animal Well.exe\" (the Windows version of the game).";
    panel.prompt = @"Use This File";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return nil;
    NSString *path = panel.URL.path;
    if (usable(path)) return adopt_game_file(path, NO);
    ask(@"This file cannot be used.",
        @"The loader works with one exact version of Animal Well.exe, and this file is a different version or a "
         "different file.\n\nThe two download choices fetch the right version.", @[ @"OK" ]);
    return nil;
}

/* way 2: SteamCMD in a Terminal window.
 * The script (get_game_files.sh, run as ~/.animalwellloader/get_game_files.command) reports through three small
 * files in ~/.animalwellloader: download.pid (its process number), download.status (running / done / failed /
 * cancelled / closed) and download.cancel (written by this app to make it stop). */
static NSString *work_file(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@".animalwellloader"] stringByAppendingPathComponent:name];
}

static NSString *steamcmd_status(void) {
    NSString *text = [NSString stringWithContentsOfFile:work_file(@"download.status")
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* Has the download ended without success? (failed, cancelled, the Terminal window closed, or never started) */
static BOOL steamcmd_stopped(NSDate *started) {
    NSString *status = steamcmd_status();
    if ([status isEqualToString:@"done"]) return NO;                 /* the file is about to be found */
    if (status.length && ![status isEqualToString:@"running"]) return YES;
    NSString *pidText = [NSString stringWithContentsOfFile:work_file(@"download.pid")
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    pid_t pid = (pid_t)pidText.intValue;
    if (pid <= 0) return -[started timeIntervalSinceNow] > 20;        /* Terminal never ran the script */
    return kill(pid, 0) != 0 && errno == ESRCH;                       /* the script is gone but did not say "done" */
}

static BOOL start_steamcmd(void) {
    NSString *script = [[NSBundle mainBundle] pathForResource:@"get_game_files" ofType:@"sh"];
    if (!script) return NO;
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:work_file(@"") withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in @[ @"download.pid", @"download.status", @"download.cancel" ])
        [files removeItemAtPath:work_file(name) error:nil];
    /* run a fresh copy of the script: Terminal opens files that end in .command */
    NSString *command = work_file(@"get_game_files.command");
    [[NSData dataWithContentsOfFile:script] writeToFile:command atomically:YES];
    [files setAttributes:@{ NSFilePosixPermissions : @0755 } ofItemAtPath:command error:nil];
    return [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:command]];
}

/* Stop the download completely: the script sees download.cancel, stops SteamCMD and closes its window. */
static void cancel_steamcmd(void) {
    [@"cancel" writeToFile:work_file(@"download.cancel") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDate *asked = [NSDate date];
    while (-[asked timeIntervalSinceNow] < 8) {                      /* give it a moment to wind down */
        NSString *status = steamcmd_status();
        if (status.length && ![status isEqualToString:@"running"]) break;
        [NSThread sleepForTimeInterval:0.25];
    }
}

static NSString *download_with_steamcmd(void) {
    if (![[NSBundle mainBundle] pathForResource:@"get_game_files" ofType:@"sh"]) {
        ask(@"The download script is missing.", @"This copy of the app was not built with build_app.sh.", @[ @"OK" ]);
        return nil;
    }
    if (ask(@"Download with SteamCMD",
            @"SteamCMD is Valve's own download tool.\n\n"
             "A Terminal window will open. It downloads SteamCMD from Valve, then asks for your Steam account "
             "name, your password and your Steam Guard code. You type them into SteamCMD in that window - this app "
             "never sees them.\n\nSteamCMD then downloads the game file (30 MB). Your account must own Animal Well.",
            @[ @"Open Terminal", @"Back" ]) != NSAlertFirstButtonReturn) return nil;

    for (;;) {
        start_steamcmd();
        NSDate *started = [NSDate date];
        BOOL stopped = NO;
        NSString *path = wait_for_game_file(@"Downloading with SteamCMD",
            @"Follow the steps in the Terminal window.\n\nThe download is small (30 MB) but can take several minutes: "
             "Steam sometimes picks a slow server and waits a long time before it tries another.\n\n"
             "This message closes by itself when the game file has arrived, and the Terminal window closes too.",
            @[ @"Cancel" ], NULL, ^BOOL { return steamcmd_stopped(started); }, &stopped);
        if (path) return adopt_game_file(path, YES);

        NSModalResponse next;
        if (stopped) {                                              /* it ended by itself, or its window was closed */
            next = ask(@"The download did not finish",
                       @"SteamCMD stopped, or its Terminal window was closed, before the game file arrived. If the "
                        "Terminal window is still open, it shows what went wrong.",
                       @[ @"Try Again", @"Back" ]);
        } else {                                                    /* the Cancel button */
            cancel_steamcmd();
            next = ask(@"Download cancelled", @"The SteamCMD download was stopped.", @[ @"Try Again", @"Back" ]);
        }
        if (next != NSAlertFirstButtonReturn) return nil;
    }
}

/* way 3: the Steam app's own console */
static void copy_depot_command(void) {
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    [board clearContents];
    [board setString:DEPOT_COMMAND forType:NSPasteboardTypeString];
}

static void restart_steam_with_console(void) {
    for (NSRunningApplication *steam in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.valvesoftware.steam"]) [steam terminate];
    for (int i = 0; i < 60; i++) {                          /* give it up to 30 seconds to close */
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.valvesoftware.steam"].count == 0) break;
        [NSThread sleepForTimeInterval:0.5];
    }
    NSTask *task = [NSTask new];                            /* the same as: open -a Steam --args -console */
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[ @"-a", @"Steam", @"--args", @"-console" ];
    [task launch];
}

static NSString *download_with_steam_app(void) {
    if (ask(@"Download with the Steam App",
            @"Steam has a console that can download the game file. Your account must own Animal Well, and Steam "
             "must be logged in.\n\n"
             "1. This app opens the console in Steam.\n"
             "2. It copies the download command for you. Click into the text field of the console, paste with "
             "Command-V and press Return.\n"
             "3. Wait until the console says \"Depot download complete\".",
            @[ @"Open the Steam Console", @"Back" ]) != NSAlertFirstButtonReturn) return nil;
    remove_steam_download_folder();         /* a leftover from an earlier download would make Steam skip this one */
    copy_depot_command();
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"steam://open/console"]];
    for (;;) {
        NSModalResponse pressed = 0;
        NSString *text = [NSString stringWithFormat:
            @"Steam should now show a page named CONSOLE. Click into its text field, paste with Command-V and press "
             "Return. The command is already copied:\n\n%@\n\n"
             "Steam shows no progress. The download is small (30 MB) but can take several minutes, because Steam "
             "sometimes picks a slow server. This message closes by itself when the download is complete.\n\n"
             "No console in Steam? Then Steam has to be closed and opened again with its console switched on.",
            DEPOT_COMMAND];
        NSString *path = wait_for_game_file(@"Paste the command into Steam's console", text,
            @[ @"Copy the Command Again", @"Restart Steam with Its Console", @"Back" ], &pressed, NULL, NULL);
        if (path) return adopt_game_file(path, YES);
        if (pressed == NSAlertFirstButtonReturn) {
            copy_depot_command();
        } else if (pressed == NSAlertSecondButtonReturn) {
            if (ask(@"Steam will be closed now",
                    @"In the next step Steam is closed and opened again with its console. Downloads that are "
                     "running in Steam are interrupted.",
                    @[ @"Close and Reopen Steam", @"Cancel" ]) == NSAlertFirstButtonReturn) {
                restart_steam_with_console();
                copy_depot_command();
            }
        } else {
            return nil;
        }
    }
}

/* Where is the user's Animal Well.exe? A remembered or already downloaded file is used without asking. Only the
 * exact build the loader was made for is accepted (game_exe_supported compares the file's SHA-256 fingerprint). */
/* The app's name as the user sees it in Finder (the .app's file name) - not the name in the menu bar, which is
 * just "Animal Well". Asked at run time, so the dialog stays right if the app is renamed. */
static NSString *app_file_name(void) {
    NSString *bundle = [NSBundle mainBundle].bundlePath;
    if ([bundle.pathExtension isEqualToString:@"app"]) return bundle.lastPathComponent.stringByDeletingPathExtension;
    return @"This program";                                        /* started as a bare program, not as an app */
}

static NSString *find_game_file(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:@"AskForGameFile"]) {
        NSString *path = [defaults stringForKey:kExeKey];
        if (usable(path)) return path;
        path = downloaded_game_file();
        if (path) return adopt_game_file(path, YES);
    }
    for (;;) {
        NSString *name = app_file_name();
        NSModalResponse choice = ask([name stringByAppendingString:@" needs your copy of the game"],
            [name stringByAppendingString:@" runs the Windows version of Animal Well, which you must own. It needs "
                                           "the file \"Animal Well.exe\" from it.\n\nHow do you want to provide it?"],
            @[ @"Choose a File…", @"Download with SteamCMD", @"Download with the Steam App", @"Quit" ]);
        NSString *path = nil;
        if (choice == NSAlertFirstButtonReturn) path = choose_game_file();
        else if (choice == NSAlertSecondButtonReturn) path = download_with_steamcmd();
        else if (choice == NSAlertThirdButtonReturn) path = download_with_steam_app();
        else exit(0);
        if (path) return path;
    }
}

/* Steam is optional. Valve's library is not part of this program; every Steam game for the Mac contains a copy.
 * Use the copy that worked last time, else look through the installed Steam games (once - can take a moment). */
static BOOL connect_steam(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *stored = [defaults stringForKey:kSteamKey];
    if (stored && [files fileExistsAtPath:stored] && game_steam_start(stored.fileSystemRepresentation)) return YES;

    NSString *games = [NSHomeDirectory() stringByAppendingPathComponent:
                       @"Library/Application Support/Steam/steamapps/common"];
    int tried = 0;
    for (NSString *relative in [files enumeratorAtPath:games]) {
        if (![relative.lastPathComponent isEqualToString:@"libsteam_api.dylib"]) continue;
        NSString *full = [games stringByAppendingPathComponent:relative];
        if (game_steam_start(full.fileSystemRepresentation)) {
            [defaults setObject:full forKey:kSteamKey];
            return YES;
        }
        if (++tried >= 12) break;
    }
    return NO;
}

/* ------------------------------------------------------------------ Steam Cloud
 * The Steam app does not sync the save of a Windows-only game on a Mac. steamcloud/steamcloud.m does it itself:
 * it signs in to Steam (once, by QR code) and brings the save file and the game's Steam Cloud save in line -
 * here, each time before the game starts and after it has ended. Never while the game runs: the game keeps its
 * save in memory and writes the file whenever it saves.
 * It is optional (menu "Steam Cloud Sync…"); without a sign-in nothing here does anything. */
#define STEAM_APP_ID     813230
#define CLOUD_SAVE_NAME  "%WinAppDataLocalLow%Billy Basso/Animal Well/AnimalWell.sav"      /* the save's name in the cloud */

static NSString *g_cloudSave;           /* the save file that is kept in line with the cloud; nil = this run does not sync */
static BOOL g_cloudPostponed;           /* the user answered a conflict with "Not Now": do not ask again in this run */
static BOOL g_gameRunning;              /* between the game's start and its end: the save file must not be replaced then */
static void cloud_menu(void);

static NSString *date_text(uint64_t seconds_since_1970) {
    return [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds_since_1970]
                                          dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterShortStyle];
}

/* The sync is "on" from a sign-in until the user signs out in the menu: the account name is kept in the loader's
 * settings meanwhile. If the sync is on but the sign-in is gone or no longer good, the user did not do that - and
 * has to be told, or the save would silently stop reaching the Steam Cloud. */
static NSString *const kCloudOnKey = @"SteamCloudAccount";
static void cloud_set_on(const char *account) {             /* NULL = off */
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (account) [defaults setObject:@(account) forKey:kCloudOnKey];
    else [defaults removeObjectForKey:kCloudOnKey];
}
/* Say once that the sign-in was lost, and offer to sign in again right away. What is left of the old sign-in is
 * removed and the sync is off from then on, so the message does not come again. */
static void cloud_tell_signed_out(NSString *why) {
    printf("Steam Cloud: signed out - %s\n", why.UTF8String);
    cloud_set_on(NULL);
    steamcloud_sign_out();
    NSModalResponse answer = ask(@"You are signed out of Steam",
        [NSString stringWithFormat:@"%@\n\nYour save is not synced with the Steam Cloud until you sign in again - now, or "
                                    "later with \"Steam Cloud Sync…\" in the menu. Your save on this Mac is fine.", why],
        @[ @"Sign In Again…", @"Later" ]);
    if (answer == NSAlertFirstButtonReturn) cloud_menu();   /* the same dialogs as from the menu */
}

/* `when` is "start" or "end" (for the log). Whatever goes wrong, the game must still start and end normally. */
static void cloud_sync(const char *when) {
    char error[512] = "", account[256] = "";
    if (!g_cloudSave) return;
    if (!steamcloud_signed_in(account, sizeof account)) {
        /* Each build of the loader keeps its sign-in in a Keychain entry of its own (see steamcloud.m): after an
         * update the sync is still "on" in the settings, or the old build's entry is still there, but this build
         * has no sign-in. */
        if ([[NSUserDefaults standardUserDefaults] stringForKey:kCloudOnKey] || steamcloud_other_build_login())
            cloud_tell_signed_out(@"The loader was updated, and for your safety a new version cannot use the Steam "
                                   "sign-in of the one before.");
        return;
    }
    cloud_set_on(account);                                  /* also for sign-ins from before this was remembered */
    if (g_cloudPostponed) return;
    if (!steamcloud_connect(error, sizeof error)) {
        printf("Steam Cloud (%s): not synced - %s\n", when, error);
        if (steamcloud_login_rejected())
            cloud_tell_signed_out(@"Steam no longer accepts the saved sign-in. It has run out, or it was removed from "
                                   "your account's devices (Steam Guard), or the account's password was changed.");
        return;
    }
    steamcloud_conflict conflict = { 0 };
    steamcloud_sync_result result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, g_cloudSave.fileSystemRepresentation,
                                                    STEAMCLOUD_WINDOWS, STEAMCLOUD_ASK, &conflict, error, sizeof error);
    if (result == STEAMCLOUD_CONFLICT) {
        NSString *text = [NSString stringWithFormat:
            @"This Mac: last changed %@\nSteam Cloud: last changed %@\n\nWhich one do you want to keep? "
             "The other one is kept as a backup file in the save folder.",
            date_text(conflict.local_time), date_text(conflict.cloud_time)];
        NSModalResponse answer = ask(@"Your save is different on this Mac and in the Steam Cloud", text,
                                     @[ @"Use Steam Cloud's", @"Use This Mac's", @"Not Now" ]);
        if (answer == NSAlertThirdButtonReturn) {
            g_cloudPostponed = YES;
        } else {
            result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, g_cloudSave.fileSystemRepresentation, STEAMCLOUD_WINDOWS,
                                     answer == NSAlertFirstButtonReturn ? STEAMCLOUD_KEEP_CLOUD : STEAMCLOUD_KEEP_LOCAL,
                                     NULL, error, sizeof error);
        }
    }
    steamcloud_disconnect();
    printf("Steam Cloud (%s): %s%s\n", when,
           result == STEAMCLOUD_IN_SYNC ? "the save is the same here and in the cloud" :
           result == STEAMCLOUD_DOWNLOADED ? "took the cloud's save (the one that was here is kept as .before-download)" :
           result == STEAMCLOUD_UPLOADED ? "sent this Mac's save to the cloud" :
           result == STEAMCLOUD_CONFLICT ? "the saves differ; the user chose to decide later" : "sync failed - ",
           result == STEAMCLOUD_SYNC_FAILED ? error : "");
    if (result == STEAMCLOUD_SYNC_FAILED && !strcmp(when, "end"))
        ask(@"The save could not be sent to the Steam Cloud",
            [NSString stringWithFormat:@"%s\n\nYour save on this Mac is fine. It is synced the next time the game starts.", error],
            @[ @"OK" ]);
}

/* Run a block on the main thread - also while a dialog is open (a dialog runs the main thread in a mode of its
 * own, in which ordinary "do this on the main thread" requests wait). */
static void on_main_thread(void (^block)(void)) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

/* macOS can make QR codes itself (Core Image) */
static NSImage *qr_image(NSString *text) {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *dots = [filter.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(8, 8)];    /* 8 pixels per dot */
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCIImage:dots];
    NSImage *image = [[NSImage alloc] initWithSize:bitmap.size];
    [image addRepresentation:bitmap];
    return image;
}

/* steamcloud_sign_in calls this (on its own thread) with the address to show as a QR code, again whenever
 * Steam replaces it. `context` is the picture view in the dialog. */
static void cloud_show_qr(const char *address, void *context) {
    NSImageView *view = (__bridge NSImageView *)context;
    NSString *text = @(address);
    on_main_thread(^{ view.image = qr_image(text); });
}

/* Start the loader again once this process has ended, with the arguments it was started with. */
static void restart_when_ended(void) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSArray<NSString *> *rest = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSMutableArray<NSString *> *command = [NSMutableArray array];
    if ([bundle.pathExtension isEqualToString:@"app"]) {            /* the app: let macOS open it, as a double-click does */
        [command addObjectsFromArray:@[ @"/usr/bin/open", @"-n", bundle ]];
        if (rest.count) [command addObject:@"--args"];
    } else {
        [command addObject:NSBundle.mainBundle.executablePath];     /* a bare program (terminal test) */
    }
    [command addObjectsFromArray:rest];
    /* a shell that waits until this process ($0 = its number) is gone, then becomes the command ("$@") */
    NSMutableArray<NSString *> *shell = [NSMutableArray arrayWithObjects:@"-c",
        @"while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec \"$@\"",
        [NSString stringWithFormat:@"%d", getpid()], nil];
    [shell addObjectsFromArray:command];
    NSError *problem = nil;
    if (![NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/bin/sh"] arguments:shell error:&problem terminationHandler:nil])
        printf("could not arrange the restart: %s\n", problem.localizedDescription.UTF8String);
}

/* When the game's save in the Steam Cloud was last changed; 0 = the cloud has none, -1 = could not look. */
static int64_t cloud_save_time(char *error, size_t error_size) {
    enum { MAX_FILES = 512 };
    steamcloud_file *files = calloc(MAX_FILES, sizeof *files);
    int count = steamcloud_list(STEAM_APP_ID, files, MAX_FILES, error, error_size);
    int64_t time = count < 0 ? -1 : 0;
    for (int i = 0; i < count && i < MAX_FILES; i++)
        if (!strcmp(files[i].name, CLOUD_SAVE_NAME)) time = (int64_t)files[i].time;
    free(files);
    return time;
}

/* Right after a sign-in: compare the save here with the one in the Steam Cloud and, if they differ, let the user
 * choose at once which one to keep. `title` and `intro` open every message shown here.
 *
 * Unlike cloud_sync this runs while the game does, and the game keeps its save in memory. Sending this Mac's save
 * to the cloud is harmless then. Taking the cloud's is not: the game would write its old save over the new file the
 * next time it saves. So the game's saving is switched off first (game_lock_save), the file is replaced, and the
 * loader starts again - the game then reads the cloud's save like any other. */
static void cloud_first_sync(NSString *title, NSString *intro) {
    char error[512] = "";
    const char *save = g_cloudSave.fileSystemRepresentation;
    NSString *later = @"It is tried again when you quit the game.";
    /* What an earlier sign-in (maybe of another account) remembered about the two sides says nothing now. Without
     * it, two saves that differ are a conflict: never settled without asking. */
    [[NSFileManager defaultManager] removeItemAtPath:[g_cloudSave stringByAppendingString:@".cloudsync"] error:nil];
    if (!steamcloud_connect(error, sizeof error)) {
        printf("Steam Cloud (sign-in): could not compare the saves - %s\n", error);
        ask(title, [NSString stringWithFormat:@"%@\n\nThe Steam Cloud could not be reached just now (%s). %@", intro, error, later], @[ @"OK" ]);
        return;
    }

    /* how the two sides differ */
    steamcloud_conflict conflict = { 0 };
    steamcloud_sync_result result;
    BOOL only_cloud = NO;                                   /* the cloud has a save, this Mac has none yet */
    if (![[NSFileManager defaultManager] fileExistsAtPath:g_cloudSave]) {
        int64_t time = cloud_save_time(error, sizeof error);
        result = time < 0 ? STEAMCLOUD_SYNC_FAILED : time == 0 ? STEAMCLOUD_IN_SYNC : STEAMCLOUD_CONFLICT;
        conflict.cloud_time = time > 0 ? (uint64_t)time : 0;
        only_cloud = time > 0;
    } else {            /* sends this Mac's save if the cloud has none; otherwise changes nothing */
        result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, save, STEAMCLOUD_WINDOWS, STEAMCLOUD_ASK, &conflict, error, sizeof error);
    }

    BOOL restart = NO;
    NSString *outcome;
    if (result == STEAMCLOUD_CONFLICT) {
        NSString *text = only_cloud
            ? [NSString stringWithFormat:@"%@\n\nThe Steam Cloud has a save (last changed %@); this Mac has none yet. Do you "
                                          "want to use it?", intro, date_text(conflict.cloud_time)]
            : [NSString stringWithFormat:@"%@\n\nYour save is different on this Mac and in the Steam Cloud:\n\n"
                                          "This Mac: last changed %@\nSteam Cloud: last changed %@\n\nWhich one do you want "
                                          "to keep? The other one is kept as a backup file in the save folder.",
                                         intro, date_text(conflict.local_time), date_text(conflict.cloud_time)];
        text = [text stringByAppendingString:@"\n\nTo use the Steam Cloud's save the game starts again: what you played "
                                              "since you last saved is lost."];
        NSModalResponse answer = ask(title, text, only_cloud ? @[ @"Use Steam Cloud's and Restart", @"Not Now" ]
                                                             : @[ @"Use Steam Cloud's and Restart", @"Use This Mac's", @"Not Now" ]);
        if (answer == NSAlertFirstButtonReturn) {
            game_lock_save();                               /* the game must not write its old save over the download */
            result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, save, STEAMCLOUD_WINDOWS, STEAMCLOUD_KEEP_CLOUD, NULL, error, sizeof error);
            restart = YES;                                  /* also if it failed: only a new start makes the game save again */
        } else if (answer == NSAlertSecondButtonReturn && !only_cloud) {
            result = steamcloud_sync(STEAM_APP_ID, CLOUD_SAVE_NAME, save, STEAMCLOUD_WINDOWS, STEAMCLOUD_KEEP_LOCAL, NULL, error, sizeof error);
        }
    }
    steamcloud_disconnect();
    printf("Steam Cloud (sign-in): %s%s\n",
           result == STEAMCLOUD_IN_SYNC ? "the save is the same here and in the cloud" :
           result == STEAMCLOUD_DOWNLOADED ? "took the cloud's save (the one that was here is kept as .before-download)" :
           result == STEAMCLOUD_UPLOADED ? "sent this Mac's save to the cloud" :
           result == STEAMCLOUD_CONFLICT ? "the saves differ; the user chose to decide later" : "sync failed - ",
           result == STEAMCLOUD_SYNC_FAILED ? error : "");

    if (restart) {
        if (result != STEAMCLOUD_DOWNLOADED)
            ask(@"The Steam Cloud's save could not be fetched",
                [NSString stringWithFormat:@"%s\n\nYour save on this Mac is as it was. The game starts again now.", error], @[ @"OK" ]);
        g_cloudPostponed = YES;                             /* nothing changes any more in this run: no sync at its end */
        restart_when_ended();
        [NSApp terminate:nil];
        return;
    }
    outcome = result == STEAMCLOUD_IN_SYNC ? @"Your save here and the one in the Steam Cloud are the same." :
              result == STEAMCLOUD_UPLOADED ? @"This Mac's save was sent to the Steam Cloud." :
              result == STEAMCLOUD_CONFLICT ? @"Nothing was changed. You are asked again when you quit the game." :
              [NSString stringWithFormat:@"The saves could not be compared just now (%s). %@", error, later];
    if (result == STEAMCLOUD_CONFLICT) return;              /* "Not Now": the dialog already said everything */
    ask(title, [NSString stringWithFormat:@"%@\n\n%@", intro, outcome], @[ @"OK" ]);
}

/* What both ways of signing in end with. `error` says why if it did not work. */
static void cloud_after_sign_in(BOOL signed_in, char *error) {
    if (!signed_in) {
        printf("Steam Cloud (sign-in): did not work - %s\n", error);
        ask(@"The sign-in did not work", @(error), @[ @"OK" ]);
        return;
    }
    char account[256] = "";
    steamcloud_signed_in(account, sizeof account);
    cloud_set_on(account);
    NSString *title = @"Steam Cloud sync is on";
    NSString *intro = [NSString stringWithFormat:@"Signed in as %s. From now on your save is brought in line with the Steam "
                                                  "Cloud each time the game starts and each time it ends.", account];
    if (!g_cloudSave) { ask(title, intro, @[ @"OK" ]); return; }    /* a test run with a save of its own: no syncing */
    if (g_gameRunning) { cloud_first_sync(title, intro); return; }
    /* Signed in before the game has started or after it has ended (from the "you are signed out" message): the
     * ordinary sync does it, as at every start and end. What an earlier sign-in remembered is forgotten here too. */
    [[NSFileManager defaultManager] removeItemAtPath:[g_cloudSave stringByAppendingString:@".cloudsync"] error:nil];
    cloud_sync("sign-in");
    ask(title, intro, @[ @"OK" ]);
}

/* The sign-in dialog: shows the QR code until the user has approved the sign-in in the Steam mobile app. */
static void cloud_sign_in(void) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Sign in with the Steam mobile app";
    alert.informativeText = @"Open the Steam app on your phone, go to the Steam Guard tab (the shield), choose "
                             "\"Scan a QR code\" and scan this code. Then approve the sign-in on your phone.";
    NSImageView *picture = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 240, 240)];
    picture.imageScaling = NSImageScaleProportionallyUpOrDown;
    alert.accessoryView = picture;
    [alert addButtonWithTitle:@"Cancel"];

    static char error[512];
    __block BOOL finished = NO, signed_in = NO, dialog_open = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int ok = steamcloud_sign_in(cloud_show_qr, (__bridge void *)picture, 300, error, sizeof error);
        on_main_thread(^{
            finished = YES;
            signed_in = ok != 0;
            if (dialog_open) [NSApp abortModal];            /* closes the dialog */
        });
    });
    [alert runModal];
    dialog_open = NO;
    [alert.window orderOut:nil];
    if (!finished) { steamcloud_cancel_sign_in(); return; }         /* "Cancel" was pressed */

    cloud_after_sign_in(signed_in, error);
}

/* The other way to sign in, for people without the Steam mobile app: account name and password. */

static NSAlert *g_signingIn;            /* the "Signing in to Steam…" dialog, while it is open */

/* Ask for one line of text in a dialog. nil = cancelled. */
static NSString *ask_text(NSString *title, NSString *text, NSString *placeholder) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = text;
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    field.placeholderString = placeholder;
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert layout];
    alert.window.initialFirstResponder = field;
    return [alert runModal] == NSAlertFirstButtonReturn ? field.stringValue : nil;
}

/* steamcloud_sign_in_password calls this (on its own thread) when the account has Steam Guard. */
static int cloud_confirm(steamcloud_confirmation kind, const char *hint, char *code, size_t code_size, void *context) {
    (void)context;
    NSString *hint_text = @(hint ?: "");
    if (kind == STEAMCLOUD_APPROVE_IN_APP || kind == STEAMCLOUD_APPROVE_BY_EMAIL) {     /* nothing to type: just say what to do */
        on_main_thread(^{
            g_signingIn.informativeText = kind == STEAMCLOUD_APPROVE_IN_APP
                ? @"Now approve the sign-in in the Steam mobile app on your phone."
                : [NSString stringWithFormat:@"Steam has emailed you a link (%@). Open it to approve the sign-in.", hint_text];
        });
        return 1;
    }
    __block NSString *typed = nil;
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    on_main_thread(^{
        typed = ask_text(@"Steam Guard code",
                         [NSString stringWithFormat:@"%@\n\n%@",
                             kind == STEAMCLOUD_CODE_FROM_EMAIL ? @"Steam has emailed you a code. Type it here."
                                                                : @"Type the code the Steam mobile app shows under Steam Guard.",
                             hint_text],
                         @"code");
        dispatch_semaphore_signal(answered);
    });
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    if (!typed.length) return 0;
    snprintf(code, code_size, "%s", typed.UTF8String);
    return 1;
}

static void cloud_sign_in_with_password(void) {
    /* account name and password */
    NSAlert *form = [NSAlert new];
    form.messageText = @"Sign in to Steam";
    form.informativeText = @"Your password goes to Steam only, encrypted with Steam's own key. The loader does not keep it; "
                            "what it keeps (in your Mac's Keychain) is the sign-in Steam hands back.";
    NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 56)];
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 32, 240, 24)];
    name.placeholderString = @"Steam account name";
    NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    password.placeholderString = @"Password";
    name.nextKeyView = password;
    [fields addSubview:name];
    [fields addSubview:password];
    form.accessoryView = fields;
    [form addButtonWithTitle:@"Sign In"];
    [form addButtonWithTitle:@"Cancel"];
    [form layout];
    form.window.initialFirstResponder = name;
    if ([form runModal] != NSAlertFirstButtonReturn || !name.stringValue.length || !password.stringValue.length) return;
    NSString *account_name = [name.stringValue copy], *secret = [password.stringValue copy];
    password.stringValue = @"";

    /* "Signing in…" while steamcloud_sign_in_password works on another thread */
    g_signingIn = [NSAlert new];
    g_signingIn.messageText = @"Signing in to Steam…";
    g_signingIn.informativeText = @"";
    [g_signingIn addButtonWithTitle:@"Cancel"];
    static char error[512];
    __block BOOL finished = NO, signed_in = NO, dialog_open = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int ok = steamcloud_sign_in_password(account_name.UTF8String, secret.UTF8String, cloud_confirm, NULL, 300, error, sizeof error);
        on_main_thread(^{
            finished = YES;
            signed_in = ok != 0;
            if (dialog_open) [NSApp abortModal];
        });
    });
    [g_signingIn runModal];
    dialog_open = NO;
    [g_signingIn.window orderOut:nil];
    g_signingIn = nil;
    if (!finished) { steamcloud_cancel_sign_in(); return; }
    cloud_after_sign_in(signed_in, error);
}

/* menu "Steam Cloud Sync…" */
static void cloud_menu(void) {
    char account[256] = "";
    if (steamcloud_signed_in(account, sizeof account)) {
        NSModalResponse answer = ask(@"Steam Cloud sync is on",
            [NSString stringWithFormat:@"Signed in as %s. Your save is brought in line with the Steam Cloud each time the game "
                                        "starts and each time it ends.", account],
            @[ @"OK", @"Sign Out" ]);
        if (answer != NSAlertSecondButtonReturn) return;
        steamcloud_sign_out();
        cloud_set_on(NULL);                                 /* the user's own doing: nothing to tell them later */
        ask(@"Signed out",
            @"The save is no longer synced. Your save on this Mac and the one in the Steam Cloud both stay as they are.\n\n"
             "The sign-in is still listed in your Steam account: to remove it there too, open Steam Guard in the Steam "
             "mobile app and remove \"Animal Well Loader (Mac)\" from your devices.", @[ @"OK" ]);
        return;
    }
    NSModalResponse answer = ask(@"Sync your save with the Steam Cloud",
        @"The loader can keep your save in line with the Steam Cloud, so that your progress carries over between this "
         "Mac and the game on Windows.\n\nYou sign in once: by scanning a QR code with the Steam mobile app (the loader "
         "then never sees your password), or with your account name and password. The sign-in is kept in your Mac's "
         "Keychain.", @[ @"Sign In With QR Code…", @"Sign In With Password…", @"Cancel" ]);
    if (answer == NSAlertFirstButtonReturn) cloud_sign_in();
    else if (answer == NSAlertSecondButtonReturn) cloud_sign_in_with_password();
}

/* ------------------------------------------------------------------ application */
@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    game_steam_stop();
    for (NSWindow *window in NSApp.windows) [window orderOut:nil];      /* the game is over: no frozen picture while we sync */
    g_gameRunning = NO;
    cloud_sync("end");
}
- (void)steamCloud:(id)sender { cloud_menu(); }
- (void)showSaveFolder:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:save_folder()]];
}
- (void)forgetGameFile:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AskForGameFile"];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"The loader will ask for the game file at the next start.";
    [alert runModal];
}
@end

static AppDelegate *g_delegate;
static Renderer *g_renderer;
static NSWindow *g_window;

/* The game half has translated the exe's shaders into Metal source text; compile it. Pipelines are built later
 * (at their first use) from the functions "vs_main" and "ps00", "ps01", ... in it. */
static void compile_shaders(void) {
    NSError *error = nil;
    NSString *source = [NSString stringWithUTF8String:game_shader_source()];
    g_library = [g_device newLibraryWithSource:source options:nil error:&error];
    if (!g_library) { NSLog(@"shaders do not compile: %@", error); exit(1); }
    g_vertexFunction = [g_library newFunctionWithName:@"vs_main"];
}

static void setup_metal(void) {
    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) { fprintf(stderr, "no Metal device\n"); exit(1); }
    g_queue = [g_device newCommandQueue];
    g_textures = [NSMutableArray array];
    g_targetTextures = [NSMutableArray array];
    g_cbuffers = [NSMutableArray array];
    g_pipelineStates = [NSMutableDictionary dictionary];

    /* the one vertex layout: 4 floats (x, y, u, v), 4 colour bytes, 32 bytes per vertex */
    g_vertexLayout = [MTLVertexDescriptor vertexDescriptor];
    g_vertexLayout.attributes[0].format = MTLVertexFormatFloat4;
    g_vertexLayout.attributes[0].offset = 0;
    g_vertexLayout.attributes[0].bufferIndex = 0;
    g_vertexLayout.attributes[1].format = MTLVertexFormatUChar4Normalized;
    g_vertexLayout.attributes[1].offset = 16;
    g_vertexLayout.attributes[1].bufferIndex = 0;
    g_vertexLayout.layouts[0].stride = 32;

    /* the two samplers the shaders use: s0 = nearest + clamp, s1 = linear + wrap */
    MTLSamplerDescriptor *point = [MTLSamplerDescriptor new];
    point.minFilter = MTLSamplerMinMagFilterNearest;
    point.magFilter = MTLSamplerMinMagFilterNearest;
    point.sAddressMode = MTLSamplerAddressModeClampToEdge;
    point.tAddressMode = MTLSamplerAddressModeClampToEdge;
    g_pointSampler = [g_device newSamplerStateWithDescriptor:point];
    MTLSamplerDescriptor *bilinear = [MTLSamplerDescriptor new];
    bilinear.minFilter = MTLSamplerMinMagFilterLinear;
    bilinear.magFilter = MTLSamplerMinMagFilterLinear;
    bilinear.sAddressMode = MTLSamplerAddressModeRepeat;
    bilinear.tAddressMode = MTLSamplerAddressModeRepeat;
    g_bilinearSampler = [g_device newSamplerStateWithDescriptor:bilinear];

    g_vertexBuffer = [g_device newBufferWithLength:4 << 20 options:MTLResourceStorageModeShared];
    g_zeroBuffer = [g_device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    memset(g_zeroBuffer.contents, 0, 4096);
    MTLTextureDescriptor *one =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:1 height:1 mipmapped:NO];
    g_dummyTexture = [g_device newTextureWithDescriptor:one];
    const uint8_t black[4] = { 0, 0, 0, 0 };
    [g_dummyTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:black bytesPerRow:4];
}

/* Steam adds its overlay by loading one of its own libraries into a game it starts. When this app is started
 * some other way (double-click), it does the same itself: it starts itself once more with that library named in
 * DYLD_INSERT_LIBRARIES. Switch it off with:  defaults write local.animalwellloader NoOverlay -bool YES */
static void restart_with_overlay(char **argv) {
    if (getenv("DYLD_INSERT_LIBRARIES") || getenv("AW_OVERLAY_TRIED")) return;     /* Steam started us, or we did */
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"NoOverlay"]) return;
    NSString *overlay = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayrenderer.dylib"];
    NSString *me = [NSBundle mainBundle].executablePath;
    if (!me || ![[NSFileManager defaultManager] fileExistsAtPath:overlay]) return;
    setenv("AW_OVERLAY_TRIED", "1", 1);
    setenv("SteamAppId", "813230", 1);
    setenv("SteamGameId", "813230", 1);
    setenv("DYLD_INSERT_LIBRARIES", overlay.fileSystemRepresentation, 1);
    execv(me.fileSystemRepresentation, argv);              /* only returns if it failed: then just carry on */
    unsetenv("DYLD_INSERT_LIBRARIES");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        restart_with_overlay(argv);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        g_delegate = [AppDelegate new];
        app.delegate = g_delegate;

        NSMenu *menuBar = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        [menuBar addItem:appItem];
        NSMenu *appMenu = [NSMenu new];
        [[appMenu addItemWithTitle:@"Show Save Folder" action:@selector(showSaveFolder:) keyEquivalent:@""]
            setTarget:g_delegate];
        [[appMenu addItemWithTitle:@"Choose Another Game File…" action:@selector(forgetGameFile:) keyEquivalent:@""]
            setTarget:g_delegate];
        [[appMenu addItemWithTitle:@"Steam Cloud Sync…" action:@selector(steamCloud:) keyEquivalent:@""]
            setTarget:g_delegate];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        app.mainMenu = menuBar;
        [app activateIgnoringOtherApps:YES];

        /* Which game file, which save, which Steam library? Each one can be given as an argument:
         *     "Animal Well" ["Animal Well.exe" [save file [libsteam_api.dylib]]]      (the program inside the app)
         * What is not given is found by the app itself: the game file is remembered / found / asked for, the save
         * lives in ~/Library/Application Support/Animal Well/, Steam's library is searched for.
         * Started from Steam's launch options the game file arrives as the only argument. */
        NSString *exePath, *savePath;
        BOOL steamOn = NO;
        BOOL exeGiven = argc > 1 && argv[1][0] != '-';
        if (argc <= 2) {
            /* no terminal test: write what the loader prints to a log file in the save folder */
            NSString *log = [save_folder() stringByAppendingPathComponent:@"loader.log"];
            if (freopen(log.fileSystemRepresentation, "w", stderr)) dup2(fileno(stderr), fileno(stdout));
            setvbuf(stderr, NULL, _IONBF, 0);
        }
        if (exeGiven) {                                     /* from Steam's launch options, or the terminal */
            exePath = [NSString stringWithUTF8String:argv[1]];
            if (!game_exe_supported(argv[1])) {
                fprintf(stderr, "%s is not the supported version of Animal Well.exe\n", argv[1]);
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"This game file cannot be used.";
                alert.informativeText = @"The loader works with one exact version of Animal Well.exe, and the file "
                                         "it was started with is a different version.";
                [alert runModal];
                return 1;
            }
        } else {
            exePath = find_game_file();
        }
        savePath = argc > 2 ? [NSString stringWithUTF8String:argv[2]]
                            : [save_folder() stringByAppendingPathComponent:@"AnimalWell.sav"];
        printf("game file: %s\nsave file: %s\n", exePath.UTF8String, savePath.UTF8String);     /* goes to loader.log */
        if (argc <= 2) {                                    /* the app's own save (not one given for a test) ... */
            g_cloudSave = savePath;
            cloud_sync("start");                            /* ... is brought in line with the Steam Cloud first */
        }
        steamOn = argc > 3 ? game_steam_start(argv[3]) != 0 : connect_steam();

        setup_metal();

        NSRect rect = NSMakeRect(0, 0, WINDOW_W, WINDOW_H);
        g_window = [[NSWindow alloc] initWithContentRect:rect
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        g_window.releasedWhenClosed = NO;
        g_window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;     /* the green button = fullscreen */
        g_window.contentMinSize = NSMakeSize(320, 180);
        /* release held keys whenever the window changes state (see release_all_keys) */
        for (NSNotificationName name in @[ NSWindowDidResignKeyNotification,
                                           NSWindowWillEnterFullScreenNotification,
                                           NSWindowDidEnterFullScreenNotification,
                                           NSWindowWillExitFullScreenNotification,
                                           NSWindowDidExitFullScreenNotification ]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:g_window
                                                               queue:nil
                                                          usingBlock:^(NSNotification *note) { release_all_keys(); }];
        }
        g_window.title = steamOn ? @"ANIMAL WELL - Steam connected" : @"ANIMAL WELL";

        GameView *view = [[GameView alloc] initWithFrame:rect device:g_device];
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        view.framebufferOnly = YES;
        view.preferredFramesPerSecond = 60;                 /* the game logic assumes exactly 60 per second */
        /* the back buffer follows the window (in real pixels); the game is told its size every frame and
         * draws its picture as the largest whole multiple of 320 x 180 that fits, centred */

        /* load the exe and start the game: this creates all textures, targets and pipelines */
        game_start(exePath.fileSystemRepresentation, savePath ? savePath.fileSystemRepresentation : NULL,
                   WINDOW_W, WINDOW_H);
        g_gameRunning = YES;
        compile_shaders();
        g_quadBuffer = [g_device newBufferWithBytes:game_fullscreen_quad
                                             length:192
                                            options:MTLResourceStorageModeShared];

        start_audio();

        g_renderer = [Renderer new];
        view.delegate = g_renderer;                         /* from now on drawInMTKView runs every frame */
        g_window.contentView = view;
        [g_window center];
        [g_window makeKeyAndOrderFront:nil];
        [g_window makeFirstResponder:view];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
