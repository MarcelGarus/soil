all: assemble soil

assemble: assemble.c
	gcc assemble.c -o assemble

soil: soil.fasm
	fasm soil.s
	chmod a+x soil

run-hello:
	cat hello.recipe | ./assemble | ./soil
