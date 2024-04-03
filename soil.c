#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MEMORY_SIZE 10000000
#define TRACE_CALLS 1

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

typedef struct { int pos; char* label; int len; } LabelAndPos;
typedef struct { LabelAndPos* entries; int len; } Labels;
Labels labels;

LabelAndPos find_label(Word pos) {
  for (int j = labels.len - 1; j >= 0; j--)
    if (labels.entries[j].pos <= pos)
      return labels.entries[j];
  LabelAndPos lap;
  lap.pos = 0;
  lap.len = 0;
  return lap;
}
void print_stack_entry(Word pos) {
  printf("%8lx ", pos);
  for (int j = labels.len - 1; j >= 0; j--)
    if (labels.entries[j].pos <= pos) {
      for (int k = 0; k < labels.entries[j].len; k++)
        printf("%c", labels.entries[j].label[k]);
      break;
    }
  printf("\n");
}
void dump_and_panic(char* msg) {
  printf("%s\n", msg);
  printf("\n");
  printf("Stack:\n");
  for (int i = 0; i < shadow_stack_len; i++) print_stack_entry(shadow_stack[i]);
  print_stack_entry(IP);
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
  printf("\n");
  FILE* dump = fopen("crash", "w+");
  fwrite(mem, 1, MEMORY_SIZE, dump);
  fclose(dump);
  printf("Memory dumped to crash.\n");
  exit(1);
}

void syscall_none() { dump_and_panic("invalid syscall number"); }
void syscall_exit() { exit(REGA); }
void syscall_print() {
  for (int i = 0; i < REGB; i++) printf("%c", mem[REGA + i]);
}
void syscall_log() {
  for (int i = 0; i < REGB; i++) fprintf(stderr, "%c", mem[REGA + i]);
}
void syscall_create() {
  char filename[REGB];
  for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
  mem[REGB] = 0;
  REGA = (Word)fopen(filename, "w+");
}
void syscall_open_reading() {
  char filename[REGB];
  for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
  mem[REGB] = 0;
  REGA = (Word)fopen(filename, "r");
}
void syscall_open_writing() {
  char filename[REGB];
  for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
  mem[REGB] = 0;
  REGA = (Word)fopen(filename, "w+");
}
void syscall_read() { REGA = fread(mem + REGB, 1, REGC, (FILE*)REGA); }
void syscall_write() {
  // TODO: assert that this worked
  fwrite(mem + REGB, 1, REGC, (FILE*)REGA);
}
void syscall_close() {
  // TODO: assert that this worked
  fclose((FILE*)REGA);
}

void init_vm(Byte* bin, int len) {
  for (int i = 0; i < 8; i++) reg[i] = 0;
  SP = MEMORY_SIZE;
  mem = malloc(MEMORY_SIZE);
  for (int i = 0; i < 256; i++) syscall_handlers[i] = syscall_none;
  syscall_handlers[0] = syscall_exit;
  syscall_handlers[1] = syscall_print;
  syscall_handlers[2] = syscall_log;
  syscall_handlers[3] = syscall_create;
  syscall_handlers[4] = syscall_open_reading;
  syscall_handlers[5] = syscall_open_writing;
  syscall_handlers[6] = syscall_read;
  syscall_handlers[7] = syscall_write;
  syscall_handlers[8] = syscall_close;

  int cursor = 0;
  #define EAT_BYTE ({ \
    if (cursor >= len) panic(1, "binary incomplete"); \
    Byte byte = bin[cursor]; \
    cursor++; \
    byte; \
  })
  #define EAT_WORD ({ \
    if (cursor > len - 8) panic(1, "binary incomplete"); \
    Word word; \
    for (int i = 7; i >= 0; i--) word = (word << 8) + bin[cursor + i]; \
    cursor += 8; \
    word; \
  })
  #define CHECK_MAGIC_BYTE(c) \
    if (EAT_BYTE != c) panic(1, "magic bytes don't match");

  CHECK_MAGIC_BYTE('s')
  CHECK_MAGIC_BYTE('o')
  CHECK_MAGIC_BYTE('i')
  CHECK_MAGIC_BYTE('l')

  while (cursor < len) {
    int section_type = EAT_BYTE;
    int section_len = EAT_WORD;
    if (section_type == 0) {
      // machine code
      if (section_len >= MEMORY_SIZE) panic(1, "machine code too big");
      for (int j = 0; j < section_len; j++) mem[j] = EAT_BYTE;
    } else if (section_type == 3) {
      // debug info
      labels.len = EAT_WORD;
      labels.entries = malloc(sizeof(LabelAndPos) * labels.len);
      for (int i = 0; i < labels.len; i++) {
        labels.entries[i].pos = EAT_WORD;
        labels.entries[i].len = EAT_WORD;
        labels.entries[i].label = bin + cursor;
        cursor += labels.entries[i].len;
      }
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

typedef Byte Reg; // 4 bits would actually be enough, but meh

void run_single() {
  #define REG1 reg[mem[IP + 1] & 0x0f]
  #define REG2 reg[mem[IP + 1] >> 4]

  Byte opcode = mem[IP];
  // printf("ip %lx has opcode %x\n", IP, opcode);
  switch (opcode) {
    case 0x00: dump_and_panic("halted"); IP += 1; break; // nop
    case 0xe0: dump_and_panic("panicked"); return; // panic
    case 0xd0: REG1 = REG2; IP += 2; break; // move
    case 0xd1: REG1 = *(Word*)(mem + IP + 2); IP += 10; break; // movei
    case 0xd2: REG1 = mem[IP + 2]; IP += 3; break; // moveib
    case 0xd3: { // load
      if (REG2 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      REG1 = *(Word*)(mem + REG2); IP += 2; break;
    }
    case 0xd4: { // loadb
      if (REG2 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      REG1 = mem[REG2]; IP += 2; break;
    }
    case 0xd5: { // store
      if (REG2 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      *(Word*)(mem + REG1) = REG2; IP += 2; break;
    }
    case 0xd6: { // storeb
      if (REG2 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      mem[REG1] = REG2; IP += 2; break;
    }
    case 0xd7: SP -= 8; *(Word*)(mem + SP) = REG1; IP += 2; break; // push
    case 0xd8: REG1 = *(Word*)(mem + SP); SP += 8; IP += 2; break; // pop
    case 0xf0: IP = *(Word*)(mem + IP + 1); break; // jump
    case 0xf1: { // cjump
      if (ST != 0) IP = *(Word*)(mem + IP + 1); else IP += 9; break;
    }
    case 0xf2: {
      if (TRACE_CALLS) {
        for (int i = 0; i < shadow_stack_len; i++)
          printf(" ");
        LabelAndPos lap = find_label(*(Word*)(mem + IP + 1));
        for (int i = 0; i < lap.len; i++) printf("%c", lap.label[i]);
        for (int i = shadow_stack_len + lap.len; i < 50; i++) printf(" ");
        for (int i = SP; i < MEMORY_SIZE && i < SP + 40; i++) {
          if (i % 8 == 0) printf(" |");
          printf(" %02x", mem[i]);
        }
        printf("\n");
      }

      Word return_target = IP + 9;
      SP -= 8; *(Word*)(mem + SP) = return_target;
      shadow_stack[shadow_stack_len] = return_target; shadow_stack_len++;
      IP = *(Word*)(mem + IP + 1); break; // call
    }
    case 0xf3: { // ret
      IP = *(Word*)(mem + SP); SP += 8;
      shadow_stack_len--;
      if (shadow_stack[shadow_stack_len] != IP)
        dump_and_panic("stack corrupted");
      break;
    }
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
    case 0xa4: REG1 %= REG2; IP += 2; break; // rem
    case 0xb0: REG1 &= REG2; IP += 2; break; // and
    case 0xb1: REG1 |= REG2; IP += 2; break; // or
    case 0xb2: REG1 ^= REG2; IP += 2; break; // xor
    case 0xb3: REG1 = ~REG1; IP += 2; break; // negate
    default: dump_and_panic("invalid instruction"); return;
  }
}

void run() {
  for (int i = 0; 1; i++) {
    // dump_reg();
    // printf("Memory:");
    // for (int i = 0x18650; i < MEMORY_SIZE; i++)
    //   printf("%c%02x", i == SP ? '|' : ' ', mem[i]);
    // printf("\n");
    run_single();
  }
}

int main(int argc, char** argv) {
  size_t cap = 8;
  size_t len = 0;
  Byte *bin = (Byte*) malloc(8);
  if (bin == NULL) panic(2, "out of memory");
  for (int ch = fgetc(stdin); ch != EOF; ch = fgetc(stdin)) {
    if (len == cap) {
      cap *= 2;
      bin = realloc(bin, cap);
      if (bin == NULL) panic(2, "out of memory");
    }
    bin[len] = (Byte)ch;
    len++;
  }

  init_vm(bin, len);
  run();
}
