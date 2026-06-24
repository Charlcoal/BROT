# BROT

A mandelbrot set renderer, which ultimately aims to provide
responsive exploration at deep zooms, to the
fullest extent possible. BROT currently supports basic
perturbation, with foveated rendering around the cursor.

## Building

BROT is currently only tested on x86_64 linux, but should
theoretically work for both x86_64 and aarm64 across
linux, windows, and mac. **BROT statically links with GMP,
using GMP's own configure script. This requires a POSIX
shell, make, and m4 on the build system** (not the target).

### Cross Compiling

Cross compiling can be done with `zig build cross`,
but is a work-in-progress, and requires -fqemu
or similar emulation flags.

