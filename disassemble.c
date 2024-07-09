#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TRACE_INSTRUCTIONS 0
#define TRACE_CALLS 0
#define TRACE_SYSCALLS 0

void panic(int exit_code, const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  vfprintf(stderr, fmt, args);
  va_end(args);
  exit(exit_code);
}

typedef uint8_t Byte;
typedef uint64_t Word;

Word reg[8];  // sp, st, a, b, c, d, e, f
#define SP reg[0]
#define ST reg[1]
#define REGA reg[2]
#define REGB reg[3]
#define REGC reg[4]
#define REGD reg[5]
#define REGE reg[6]
#define REGF reg[7]

Byte* byte_code;
int byte_code_len = 0;

Byte* mem;
int mem_len = 0;

typedef struct {
  int pos;
  char* label;
  int len;
} LabelAndPos;
typedef struct {
  LabelAndPos* entries;
  int len;
} Labels;
Labels labels;

LabelAndPos find_label(Word pos) {
  for (int j = labels.len - 1; j >= 0; j--)
    if (labels.entries[j].pos <= pos) return labels.entries[j];
  LabelAndPos lap;
  lap.pos = 0;
  lap.len = 0;
  return lap;
}

void parse_binary(Byte* bin, int bin_len) {
  byte_code = 0;

  int cursor = 0;
#define EAT_BYTE                                          \
  ({                                                      \
    if (cursor >= bin_len) panic(1, "binary incomplete"); \
    Byte byte = bin[cursor];                              \
    cursor++;                                             \
    byte;                                                 \
  })
#define EAT_WORD                                                       \
  ({                                                                   \
    if (cursor > bin_len - 8) panic(1, "binary incomplete");           \
    Word word;                                                         \
    for (int i = 7; i >= 0; i--) word = (word << 8) + bin[cursor + i]; \
    cursor += 8;                                                       \
    word;                                                              \
  })
#define CHECK_MAGIC_BYTE(c) \
  if (EAT_BYTE != c) panic(1, "magic bytes don't match");

  CHECK_MAGIC_BYTE('s')
  CHECK_MAGIC_BYTE('o')
  CHECK_MAGIC_BYTE('i')
  CHECK_MAGIC_BYTE('l')

  while (cursor < bin_len) {
    int section_type = EAT_BYTE;
    int section_len = EAT_WORD;
    if (section_type == 0) {
      // byte code
      byte_code_len = section_len;
      byte_code = malloc(byte_code_len);
      for (int j = 0; j < byte_code_len; j++) byte_code[j] = EAT_BYTE;
    } else if (section_type == 1) {
      // initial memory
      mem_len = section_len;
      mem = malloc(mem_len);
      for (int j = 0; j < mem_len; j++) mem[j] = EAT_BYTE;
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

#undef EAT_BYTE
#undef EAT_WORD
#undef CHECK_MAGIC_BYTE
}

typedef Byte Reg;  // 4 bits would actually be enough, but meh

char* regs[8] = {"sp", "st", "a", "b", "c", "d", "e", "f"};

void dump_binary(void) {
  int cursor = 0;
  while (cursor < byte_code_len) {

    #define EAT_BYTE ({                                             \
        if (cursor >= byte_code_len) panic(1, "binary incomplete"); \
        Byte byte = byte_code[cursor];                              \
        cursor++;                                                   \
        byte;                                                       \
      })
    #define EAT_WORD ({                                                          \
        if (cursor > byte_code_len - 8) panic(1, "binary incomplete");           \
        Word word;                                                               \
        for (int i = 7; i >= 0; i--) word = (word << 8) + byte_code[cursor + i]; \
        cursor += 8;                                                             \
        word;                                                                    \
      })
    #define EAT_REGS ({ \
      if (cursor >= byte_code_len) panic(1, "binary incomplete"); \
      reg1 = regs[byte_code[cursor] & 0x0f]; \
      reg2 = regs[byte_code[cursor] >> 4]; \
      cursor++; \
    })

    int start = cursor;
    printf("%04x | ", start);

    #define CMD_LEN 20
    char cmd[CMD_LEN];
    cmd[0] = 0;
    char* reg1;
    char* reg2;
    switch (EAT_BYTE) {
      case 0x00: sprintf(cmd, "halt"); break;
      case 0xe0: sprintf(cmd, "panic"); break;
      case 0xe1: sprintf(cmd, "trystart %lx", EAT_WORD); break;
      case 0xe2: sprintf(cmd, "tryend"); break;
      case 0xd0: EAT_REGS; sprintf(cmd, "move %s %s", reg1, reg2); break;
      case 0xd1: EAT_REGS; sprintf(cmd, "movei %s %ld", reg1, EAT_WORD); break;
      case 0xd2: EAT_REGS; sprintf(cmd, "moveib %s %d", reg1, EAT_BYTE); break;
      case 0xd3: EAT_REGS; sprintf(cmd, "load %s %s", reg1, reg2); break;
      case 0xd4: EAT_REGS; sprintf(cmd, "loadb %s %s", reg1, reg2); break;
      case 0xd5: EAT_REGS; sprintf(cmd, "store %s %s", reg1, reg2); break;
      case 0xd6: EAT_REGS; sprintf(cmd, "storeb %s %s", reg1, reg2); break;
      case 0xd7: EAT_REGS; sprintf(cmd, "push %s", reg1); break;
      case 0xd8: EAT_REGS; sprintf(cmd, "pop %s", reg1); break;
      case 0xf0: sprintf(cmd, "jump %lx", EAT_WORD); break;
      case 0xf1: sprintf(cmd, "cjump %lx", EAT_WORD); break;
      case 0xf2: sprintf(cmd, "call %lx", EAT_WORD); break;
      case 0xf3: sprintf(cmd, "ret"); break;
      case 0xf4: sprintf(cmd, "syscall %d", EAT_BYTE); break;
      case 0xc0: EAT_REGS; sprintf(cmd, "cmp %s %s", reg1, reg2); break;
      case 0xc1: sprintf(cmd, "isequal"); break;
      case 0xc2: sprintf(cmd, "isless"); break;
      case 0xc3: sprintf(cmd, "isgreater"); break;
      case 0xc4: sprintf(cmd, "islessequal"); break;
      case 0xc5: sprintf(cmd, "isgreaterequal"); break;
      case 0xc6: sprintf(cmd, "isnotequal"); break;
      case 0xc7: EAT_REGS; sprintf(cmd, "fcmp %s %s", reg1, reg2); break;
      case 0xc8: sprintf(cmd, "isequal"); break;
      case 0xc9: sprintf(cmd, "isless"); break;
      case 0xca: sprintf(cmd, "isgreater"); break;
      case 0xcb: sprintf(cmd, "islessequal"); break;
      case 0xcc: sprintf(cmd, "isgreaterequal"); break;
      case 0xcd: sprintf(cmd, "isnotequal"); break;
      case 0xce: EAT_REGS; sprintf(cmd, "inttofloat %s", reg1); break;
      case 0xcf: EAT_REGS; sprintf(cmd, "floattoint %s", reg1); break;
      case 0xa0: EAT_REGS; sprintf(cmd, "add %s %s", reg1, reg2); break;
      case 0xa1: EAT_REGS; sprintf(cmd, "sub %s %s", reg1, reg2); break;
      case 0xa2: EAT_REGS; sprintf(cmd, "mul %s %s", reg1, reg2); break;
      case 0xa3: EAT_REGS; sprintf(cmd, "div %s %s", reg1, reg2); break;
      case 0xa4: EAT_REGS; sprintf(cmd, "rem %s %s", reg1, reg2); break;
      case 0xa5: EAT_REGS; sprintf(cmd, "fadd %s %s", reg1, reg2); break;
      case 0xa6: EAT_REGS; sprintf(cmd, "fsub %s %s", reg1, reg2); break;
      case 0xa7: EAT_REGS; sprintf(cmd, "fmul %s %s", reg1, reg2); break;
      case 0xa8: EAT_REGS; sprintf(cmd, "fdiv %s %s", reg1, reg2); break;
      case 0xb0: EAT_REGS; sprintf(cmd, "and %s %s", reg1, reg2); break;
      case 0xb1: EAT_REGS; sprintf(cmd, "or %s %s", reg1, reg2); break;
      case 0xb2: EAT_REGS; sprintf(cmd, "xor %s %s", reg1, reg2); break;
      case 0xb3: EAT_REGS; sprintf(cmd, "not %s", reg1); break;
      default: panic(1, "invalid instruction %dx", byte_code[cursor - 1]);
    }

    LabelAndPos lap = find_label(start);

    printf("%-20s | ", cmd);
    for (int i = 0; i < lap.len; i++) printf("%c", lap.label[i]);
    printf("\n");
  }

  printf("\nMemory:");
  for (int i = 0; i < mem_len; i++) printf(" %02x", mem[i]);
  printf("\n");
}

int main(int argc, char** argv) {
  if (argc < 2) panic(1, "Usage: %s <file>\n", argv[0]);

  FILE* file = fopen(argv[1], "rb");
  if (file == NULL) panic(3, "couldn't open file %s", argv[1]);
  fseek(file, 0L, SEEK_END);
  size_t len = ftell(file);
  rewind(file);
  Byte* bin = (Byte*)malloc(len + 1);
  if (bin == NULL) panic(2, "out of memory");
  size_t read = fread(bin, sizeof(char), len, file);
  if (read != len) panic(4, "file size changed after fseek");
  bin[read] = 0;
  fclose(file);

  parse_binary(bin, len);
  dump_binary();
}
