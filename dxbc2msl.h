/* dxbc2msl.h - translate one compiled Direct3D pixel shader (DXBC bytecode) into a Metal Shading Language function.
 * Plain C, no dependencies: it reads the bytecode itself, so it runs on the Mac (tools/dxbc2msl.py does the same
 * job from Microsoft's disassembly and needs Windows; the two produce identical text). */
#ifndef DXBC2MSL_H
#define DXBC2MSL_H
#include <stddef.h>
#include <stdint.h>

/* Shared start of the Metal source: macros, the vertex / fragment structs and the vertex shader "vs_main". */
const char *dxbc2msl_head(void);

/* Translate one pixel shader. Returns a malloc'ed, zero-terminated string holding
 *     fragment float4 <name>(...) { ... }
 * or NULL on failure (then *error points to a static message). texture_slots receives a bit mask of the texture
 * slots the shader reads (bit n = slot n). */
char *dxbc2msl_pixel_shader(const uint8_t *bytecode, size_t size, const char *name, unsigned *texture_slots,
                            const char **error);

#endif
