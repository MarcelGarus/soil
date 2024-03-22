all: assemble soil

assemble:
	gcc assemble.c -o assemble

soil:
	fasm soil.fasm
	chmod a+x soil

run-hello:
	cat hello.recipe | ./assemble | ./soil
