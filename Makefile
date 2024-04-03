all: assemble soil soil-c

assemble: assemble.c
	gcc assemble.c -o assemble

soil: soil.s
	fasm soil.s
	chmod a+x soil

soil-c: soil.c
	gcc soil.c -o soil-c

run-hello:
	cat hello.recipe | ./assemble | ./soil
