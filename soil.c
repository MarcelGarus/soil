#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

void panic(int exit_code, char* msg) {
  printf("%s\n", msg);
  exit(exit_code);
}

typedef uint8_t Byte;
typedef uint64_t Word;

Word reg[16]; // ip, sp, st, a, b, c, d, e
#define IP reg[0]
#define SP reg[1]
#define ST reg[2]
#define REGA reg[3]
#define REGB reg[4]
#define REGC reg[5]
#define REGD reg[6]
#define REGE reg[7]

Byte* mem;

void (*devices[256])();

void device_none() { panic(1, "Device not connected."); }
void device_exit() { exit(REGA); }
void device_stdout() { for (int i = 0; i < REGB; i++) printf("%c", mem[REGA + i]); }

Word read_word(Byte* bin, Word pos) {
  Word word;
  for (int i = 7; i >= 0; i--)
    word = (word << 8) + bin[pos + i];
  return word;
}

void init_vm(Byte* bin, int len) {
  for (int i = 0; i < 8; i++) reg[i] = 0;
  mem = malloc(1000);
  for (int socket = 0; socket < 256; socket++) devices[socket] = device_none;

  if (bin[0] != 's' || bin[1] != 'o' || bin[2] != 'i' || bin[3] != 'l')
    panic(1, "Magic bytes don't match.");

  int cursor = 4;
  while (cursor < len) {
    int section_type = bin[cursor];
    int section_len = read_word(bin, cursor + 1);
    cursor += 9;
    if (section_type == 2) {
      // devices
      int num_devices = bin[cursor];
      cursor++;
      for (int socket = 0; socket < num_devices; socket++) {
        int hint_len = bin[cursor];
        char* hint = bin + cursor + 1;
        if (hint_len == 4 && strncmp(hint, "exit", 4) == 0) {
          devices[socket] = device_exit;
        } else if (hint_len == 6 && strncmp(hint, "stdout", 6) == 0) {
          devices[socket] = device_stdout;
        } else {
          panic(1, "Unknown device.");
        }
        cursor += hint_len + 1;
      }
    } else if (section_type == 3) {
      // machine code
      printf("machine code is at %x\n", cursor);
      for (int j = 0; j < section_len; j++) mem[j] = bin[cursor + j];
      cursor += section_len;
    } else {
      cursor += section_len;
    }
  }

  printf("Memory:");
  for (int i = 0; i < 100; i++) printf(" %02x", mem[i]);
  printf("\n");
}

void dump_reg() {
  printf(
    "ip = %ld, sp = %ld, st = %ld, a = %ld, b = %ld, c = %ld, d = %ld, e = "
    "%ld\n", reg[0], reg[1], reg[2], reg[3], reg[4], reg[5], reg[6], reg[7]);
}

typedef Byte Reg; // 4 bits would actually be enough, but meh

void run_single() {
  #define REG1 reg[mem[IP + 1] & 0x0f]
  #define REG2 reg[mem[IP + 1] >> 4]

  Byte opcode = mem[IP];
  switch (opcode) {
    case 0x00: IP += 1; break; // nop
    case 0xe0: panic(1, "VM panicked"); return; // panic
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
    case 0xf4: devices[mem[IP + 1]](); IP += 2; break; // devicecall
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

void run() {
  for (int i = 0; i < 10; i++) {
    dump_reg();
    run_single();
  }
}

int main(int argc, char** argv) {
  size_t cap = 8;
  size_t len = 0;
  char *bin = (char*) malloc(8);
  if (bin == NULL) panic(2, "Out of memory.");
  char ch;
  do {
    ch = fgetc(stdin);
    if (len == cap) {
      cap *= 2;
      bin = realloc(bin, cap);
      if (bin == NULL) panic(2, "Out of memory.");
    }
    bin[len] = ch;
    len++;
  } while (ch != EOF);

  init_vm(bin, len);
  run();
}
