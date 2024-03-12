#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

void panic(int exit_code, char* msg) {
  printf("%s\n", msg);
  exit(exit_code);
}

typedef uint8_t Byte;
typedef uint64_t Word;

typedef struct Vm {
  Word reg[16]; // ip, sp, st, a, b, c, d, e
  Byte* mem;
} Vm;

Vm create_vm() {  // int image_len, char* image
  Vm vm;
  for (int i = 0; i < 8; i++) vm.reg[i] = 0;
  vm.mem = malloc(1000);
  return vm;
}

void dump_reg(Vm vm) {
  printf(
      "ip = %ld, sp = %ld, st = %ld, a = %ld, b = %ld, c = %ld, d = %ld, e = "
      "%ld\n",
      vm.reg[0], vm.reg[1], vm.reg[2], vm.reg[3], vm.reg[4], vm.reg[5],
      vm.reg[6], vm.reg[7]);
}

typedef Byte Reg; // 4 bits would actually be enough, but meh

void run_single(Vm* vm) {
  Word* reg = vm->reg;
  Byte* mem = vm->mem;

  #define IP reg[0]
  #define SP reg[1]
  #define ST reg[2]
  #define REG1 reg[mem[IP + 1] & 0x0f]
  #define REG2 reg[mem[IP + 1] >> 4]

  Byte opcode = mem[IP];
  printf("opcode = %x\n", opcode);
  switch (opcode) {
    case 0x00: IP += 1; break; // nop
    case 0xe0: printf("Panicked\n"); return; // panic
    case 0xd0: REG1 = REG2; IP += 2; break; // move
    case 0xd1: REG1 = *(Word*)(mem + IP + 2); IP += 10; break; // movei
    case 0xd2: REG1 = mem[IP + 2]; IP += 3; break; // moveib
    case 0xd3: REG1 = *(Word*)(mem + REG2); IP += 2; break; // load
    case 0xd4: REG1 = mem[REG2]; IP += 2; break; // loadb
    case 0xd5: *(Word*)(mem + REG1) = REG2; IP += 2; break; // store
    case 0xd6: mem[REG1] = REG2; IP += 2; break; // storeb
    case 0xd7: SP -= 8; *(Word*)(mem + SP) = REG1; IP += 2; break; // push
    case 0xd8: REG1 = *(Word*)(mem + SP); SP += 8; IP += 2; break; // pop
    case 0xf0: IP = *(Word*)(mem + IP + 1); break; // jump
    case 0xf1: if (ST != 0) IP = *(Word*)(mem + IP + 1); break; // cjump
    case 0xf2: SP -= 8; *(Word*)(mem + SP) = REG1; IP = *(Word*)(mem + IP + 1); break; // call
    case 0xf3: IP = *(Word*)(mem + SP); SP += 8; break; // ret
    case 0xf4: printf("TODO: syscall\n"); return; // syscall
    case 0xc0: ST = REG1 - REG2; IP += 2; break; // cmp
    case 0xc1: ST = ST == 0 ? 1 : 0; IP += 1; break; // isequal
    case 0xc2: ST = (int64_t)ST < 0 ? 1 : 0; IP += 1; break; // isless
    case 0xc3: ST = (int64_t)ST > 0 ? 1 : 0; IP += 1; break; // isgreater
    case 0xc4: ST = (int64_t)ST <= 0 ? 1 : 0; IP += 1; break; // islessequal
    case 0xc5: ST = (int64_t)ST >= 0 ? 1 : 0; IP += 1; break; // isgreaterequal
    case 0xa0: REG1 += REG2; IP += 2; break; // add
    case 0xa1: REG1 -= REG2; IP += 2; break; // sub
    case 0xa2: REG1 *= REG2; IP += 2; break; // mul
    case 0xa3: REG1 /= REG2; IP += 2; break; // div
    case 0xb0: REG1 &= REG2; IP += 2; break; // and
    case 0xb1: REG1 |= REG2; IP += 2; break; // or
    case 0xb2: REG1 ^= REG2; IP += 2; break; // xor
    case 0xb3: REG1 = ~REG2; IP += 2; break; // negate
    default: printf("Invalid instruction.\n"); return;
  }
}

void test_fib_vm() {
  Vm vm = create_vm();
  Byte code[] = {
      0xd2, 0b00000011, 0, // moveib a 0
      0xd2, 0b00000100, 1, // moveib b 1
      0xd2, 0b00000101, 0, // moveib c 0
      0xd0, 0b01000101,    // move c b
      0xa0, 0b00110100,    // add b a
      0xd0, 0b01010011,    // move a c
      0xf0, 9,             // jump 0
  };
  size_t code_len = sizeof(code) / sizeof(Byte);

  for (int i = 0; i < code_len; i++)
    vm.mem[i] = code[i];

  for (int i = 0; i < 100; i++) {
    dump_reg(vm);
    run_single(&vm);
  }
}

int main(int argc, char** argv) {
  test_fib_vm();
  exit(0);
  
  if (argc < 2) panic(1, "Expected file to run.");
  FILE* file = fopen(argv[1], "r");

  size_t cap = 8;
  size_t len = 0;
  char *image = (char*) malloc(8);
  if (image == NULL) panic(2, "Out of memory.");
  char ch;

  do {
    ch = fgetc(file);
    if (len == cap) {
      cap *= 2;
      image = realloc(image, cap);
      if (image == NULL) panic(2, "Out of memory.");
    }
    image[len] = ch;
    len++;
  } while (ch != EOF);

  fclose(file);

  Vm vm = create_vm();
}
