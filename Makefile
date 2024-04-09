all: assemble soil-asm soil-c

assemble: assemble.c
	gcc assemble.c -o assemble

soil-asm: soil.s
	fasm soil.s soil-asm
	chmod a+x soil-asm

soil-c: soil.c
	gcc soil.c -O3 -o soil-c

run-hello:
	cat hello.recipe | ./assemble | ./soil
