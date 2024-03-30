#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define MEMORY_SIZE 100000

void panic(int exit_code, char* msg) {
  printf("%s\n", msg);
  exit(exit_code);
}

typedef uint8_t Byte;
typedef uint64_t Word;

Word reg[8]; // ip, sp, st, a, b, c, d, e
#define IP reg[0]
#define SP reg[1]
#define ST reg[2]
#define REGA reg[3]
#define REGB reg[4]
#define REGC reg[5]
#define REGD reg[6]
#define REGE reg[7]

Byte* mem;

Word shadow_stack[1024];
Word shadow_stack_len = 0;

void (*syscall_handlers[256])();

void syscall_none() { panic(1, "Invalid syscall number."); }
void syscall_exit() { exit(REGA); }
void syscall_print() { for (int i = 0; i < REGB; i++) printf("%c", mem[REGA + i]); }
void syscall_log() { for (int i = 0; i < REGB; i++) fprintf(stderr, "%c", mem[REGA + i]); }

Word read_word(Byte* bin, Word pos) {
  Word word;
  for (int i = 7; i >= 0; i--)
    word = (word << 8) + bin[pos + i];
  return word;
}

void init_vm(Byte* bin, int len) {
  for (int i = 0; i < 8; i++) reg[i] = 0;
  SP = MEMORY_SIZE;
  mem = malloc(MEMORY_SIZE);
  for (int i = 0; i < 256; i++) syscall_handlers[i] = syscall_none;
  syscall_handlers[0] = syscall_exit;
  syscall_handlers[1] = syscall_print;

  if (bin[0] != 's' || bin[1] != 'o' || bin[2] != 'i' || bin[3] != 'l')
    panic(1, "Magic bytes don't match.");

  int cursor = 4;
  while (cursor < len) {
    int section_type = bin[cursor];
    int section_len = read_word(bin, cursor + 1);
    cursor += 9;
    if (section_type == 0) {
      // machine code
      printf("machine code is at %x\n", cursor);
      for (int j = 0; j < section_len; j++) mem[j] = bin[cursor + j];
      cursor += section_len;
    } else {
      cursor += section_len;
    }
  }

  // printf("Memory:");
  // for (int i = 0; i < MEMORY_SIZE; i++) printf(" %02x", mem[i]);
  // printf("\n");
}

void dump_reg() {
  printf(
    "ip = %lx, sp = %lx, st = %lx, a = %lx, b = %lx, c = %lx, d = %lx, e = "
    "%lx\n", reg[0], reg[1], reg[2], reg[3], reg[4], reg[5], reg[6], reg[7]);
}

void dump_and_panic(char* msg) {
  printf("%s\n", msg);
  printf("\n");
  printf("Stack:\n");
  for (int i = 0; i < shadow_stack_len; i++) {
    printf("%8lx\n", shadow_stack[i]);
  }
  printf("\n");
  printf("Registers:\n");
  printf("ip = %8ld %8lx\n", IP, IP);
  printf("sp = %8ld %8lx\n", SP, SP);
  printf("st = %8ld %8lx\n", ST, ST);
  printf("a  = %8ld %8lx\n", REGA, REGA);
  printf("b  = %8ld %8lx\n", REGB, REGB);
  printf("c  = %8ld %8lx\n", REGC, REGC);
  printf("d  = %8ld %8lx\n", REGD, REGD);
  printf("e  = %8ld %8lx\n", REGE, REGE);
  exit(1);
}

typedef Byte Reg; // 4 bits would actually be enough, but meh

void run_single() {
  #define REG1 reg[mem[IP + 1] & 0x0f]
  #define REG2 reg[mem[IP + 1] >> 4]

  Byte opcode = mem[IP];
  switch (opcode) {
    case 0x00: dump_and_panic("halted"); IP += 1; break; // nop
    case 0xe0: dump_and_panic("VM panicked"); return; // panic
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
    case 0xf1: if (ST != 0) IP = *(Word*)(mem + IP + 1); else IP += 9; break; // cjump
    case 0xf2:
      Word return_target = IP + 9;
      SP -= 8; *(Word*)(mem + SP) = return_target;
      shadow_stack[shadow_stack_len] = return_target; shadow_stack_len++;
      IP = *(Word*)(mem + IP + 1); break; // call
    case 0xf3:
      IP = *(Word*)(mem + SP); SP += 8;
      shadow_stack_len--; if (shadow_stack[shadow_stack_len] != IP) dump_and_panic("Stack corrupted.");
      break; // ret
    case 0xf4: syscall_handlers[mem[IP + 1]](); IP += 2; break; // syscall
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
    default: dump_and_panic("Invalid instruction.\n"); return;
  }
}

void run() {
  for (int i = 0; 1; i++) {
    dump_reg();
    run_single();
  }
}

int main(int argc, char** argv) {
  size_t cap = 8;
  size_t len = 0;
  Byte *bin = (Byte*) malloc(8);
  if (bin == NULL) panic(2, "Out of memory.");
  for (int ch = fgetc(stdin); ch != EOF; ch = fgetc(stdin)) {
    if (len == cap) {
      cap *= 2;
      bin = realloc(bin, cap);
      if (bin == NULL) panic(2, "Out of memory.");
    }
    bin[len] = (Byte)ch;
    len++;
  }

  init_vm(bin, len);
  run();
}
