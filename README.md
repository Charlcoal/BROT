# BROT

A mandelbrot set renderer, which ultimately aims to provide
responsive thumbnail exploration at deep zooms, to the
fullest extent possible. BROT currently supports basic 32 bit
float precision, with basic foveated rendering around the cursor.

## Building

BROT is currently only tested on x86_64 linux, but should
theoretically work for other common targets. The build script
**requires glslc** to be installed on the host system, and
should work with a simple ```zig build run```.

## Running

BROT currently dynamically links to gnu gmp,
which means you need to install gmp locally to run BROT.
