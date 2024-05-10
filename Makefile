all: assemble disassemble soil-asm soil-c

assemble: assemble.c
	gcc assemble.c -o assemble
disassemble: disassemble.c
	gcc disassemble.c -o disassemble

soil-asm: soil.s
	fasm soil.s soil-asm
	chmod a+x soil-asm

soil-c: soil.c
	gcc soil.c -O3 -o soil-c

run-hello:
	cat hello.recipe | ./assemble | ./soil
