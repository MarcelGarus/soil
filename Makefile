all: assemble disassemble soil-asm soil-c soil-zig

assemble: assemble.c
	gcc assemble.c -o assemble
disassemble: disassemble.c
	gcc disassemble.c -o disassemble

soil-asm: soil.s
	fasm soil.s soil-asm
	chmod a+x soil-asm

soil-c: soil.c
	gcc soil.c -O3 -o soil-c

soil-zig: $(shell find zig/src -type f)
	cd zig; zig build -Doptimize=ReleaseFast && cp zig-out/bin/soil-zig ../soil-zig

run-hello:
	cat hello.recipe | ./assemble | ./soil
