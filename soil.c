#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MEMORY_SIZE 0x1000000
#define TRACE_INSTRUCTIONS 0
#define TRACE_CALLS 0
#define TRACE_SYSCALLS 0

void panic(int exit_code, char* msg) {
  printf("%s\n", msg);
  exit(exit_code);
}

typedef uint8_t Byte;
typedef uint64_t Word;

Word reg[8]; // sp, st, a, b, c, d, e, f
#define SP reg[0]
#define ST reg[1]
#define REGA reg[2]
#define REGB reg[3]
#define REGC reg[4]
#define REGD reg[5]
#define REGE reg[6]
#define REGF reg[7]

Byte* byte_code;
Word ip = 0;

Byte* mem;

Word call_stack[1024];
Word call_stack_len = 0;

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
  for (int i = 0; i < call_stack_len; i++) print_stack_entry(call_stack[i]);
  print_stack_entry(ip);
  printf("\n");
  printf("Registers:\n");
  printf("sp = %8ld %8lx\n", SP, SP);
  printf("st = %8ld %8lx\n", ST, ST);
  printf("a  = %8ld %8lx\n", REGA, REGA);
  printf("b  = %8ld %8lx\n", REGB, REGB);
  printf("c  = %8ld %8lx\n", REGC, REGC);
  printf("d  = %8ld %8lx\n", REGD, REGD);
  printf("e  = %8ld %8lx\n", REGE, REGE);
  printf("f  = %8ld %8lx\n", REGF, REGF);
  printf("\n");
  FILE* dump = fopen("crash", "w+");
  fwrite(mem, 1, MEMORY_SIZE, dump);
  fclose(dump);
  printf("Memory dumped to crash.\n");
  exit(1);
}

void init_syscalls(void);

void init_vm(Byte* bin, int bin_len, int argc, char** argv) {
  for (int i = 0; i < 8; i++) reg[i] = 0;
  SP = MEMORY_SIZE;
  mem = malloc(MEMORY_SIZE);

  // Push main function arguments to the stack.
  SP -= 16 * argc;
  int slice = SP;
  for (int i = 0; i < argc; i++) {
    int len = strlen(argv[i]);
    SP -= len;
    for (int j = 0; j < len; j++) mem[SP + j] = argv[i][j];
    *(Word*)(mem + slice + 16 * i) = SP;
    *(Word*)(mem + slice + 16 * i + 8) = len;
  }
  SP = SP / 8 * 8;
  SP -= 16;
  *(Word*)(mem + SP) = slice;
  *(Word*)(mem + SP + 8) = argc;

  init_syscalls();

  int cursor = 0;
  #define EAT_BYTE ({ \
    if (cursor >= bin_len) panic(1, "binary incomplete"); \
    Byte byte = bin[cursor]; \
    cursor++; \
    byte; \
  })
  #define EAT_WORD ({ \
    if (cursor > bin_len - 8) panic(1, "binary incomplete"); \
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

  while (cursor < bin_len) {
    int section_type = EAT_BYTE;
    int section_len = EAT_WORD;
    if (section_type == 0) {
      // byte code
      byte_code = malloc(section_len);
      for (int j = 0; j < section_len; j++) byte_code[j] = EAT_BYTE;
    } else if (section_type == 1) {
      // initial memory
      if (section_len >= MEMORY_SIZE) panic(1, "initial memory too big");
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

void dump_reg(void) {
  printf(
    "ip = %lx, sp = %lx, st = %lx, a = %lx, b = %lx, c = %lx, d = %lx, e = "
    "%lx, f = %lx\n", ip, SP, ST, REGA, REGB, REGC, REGD, REGE, REGF);
}

typedef Byte Reg; // 4 bits would actually be enough, but meh

void run_single(void) {
  #define REG1 reg[byte_code[ip + 1] & 0x0f]
  #define REG2 reg[byte_code[ip + 1] >> 4]

  Byte opcode = byte_code[ip];
  switch (opcode) {
    case 0x00: dump_and_panic("halted"); ip += 1; break; // nop
    case 0xe0: dump_and_panic("panicked"); return; // panic
    case 0xd0: REG1 = REG2; ip += 2; break; // move
    case 0xd1: REG1 = *(Word*)(byte_code + ip + 2); ip += 10; break; // movei
    case 0xd2: REG1 = byte_code[ip + 2]; ip += 3; break; // moveib
    case 0xd3: { // load
      if (REG2 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      REG1 = *(Word*)(mem + REG2); ip += 2; break;
    }
    case 0xd4: { // loadb
      if (REG2 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      REG1 = mem[REG2]; ip += 2; break;
    }
    case 0xd5: { // store
      if (REG1 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      *(Word*)(mem + REG1) = REG2; ip += 2; break;
    }
    case 0xd6: { // storeb
      if (REG1 >= MEMORY_SIZE) dump_and_panic("segmentation fault");
      mem[REG1] = REG2; ip += 2; break;
    }
    case 0xd7: SP -= 8; *(Word*)(mem + SP) = REG1; ip += 2; break; // push
    case 0xd8: REG1 = *(Word*)(mem + SP); SP += 8; ip += 2; break; // pop
    case 0xf0: ip = *(Word*)(byte_code + ip + 1); break; // jump
    case 0xf1: { // cjump
      if (ST != 0) ip = *(Word*)(byte_code + ip + 1); else ip += 9; break;
    }
    case 0xf2: {
      if (TRACE_CALLS) {
        for (int i = 0; i < call_stack_len; i++)
          printf(" ");
        LabelAndPos lap = find_label(*(Word*)(byte_code + ip + 1));
        for (int i = 0; i < lap.len; i++) printf("%c", lap.label[i]);
        for (int i = call_stack_len + lap.len; i < 50; i++) printf(" ");
        for (int i = SP; i < MEMORY_SIZE && i < SP + 40; i++) {
          if (i % 8 == 0) printf(" |");
          printf(" %02x", mem[i]);
        }
        printf("\n");
      }

      Word return_target = ip + 9;
      call_stack[call_stack_len] = return_target; call_stack_len++;
      ip = *(Word*)(byte_code + ip + 1); break; // call
    }
    case 0xf3: { // ret
      call_stack_len--;
      ip = call_stack[call_stack_len];
      break;
    }
    case 0xf4: syscall_handlers[byte_code[ip + 1]](); ip += 2; break; // syscall
    case 0xc0: ST = REG1 - REG2; ip += 2; break; // cmp
    case 0xc1: ST = ST == 0 ? 1 : 0; ip += 1; break; // isequal
    case 0xc2: ST = (int64_t)ST < 0 ? 1 : 0; ip += 1; break; // isless
    case 0xc3: ST = (int64_t)ST > 0 ? 1 : 0; ip += 1; break; // isgreater
    case 0xc4: ST = (int64_t)ST <= 0 ? 1 : 0; ip += 1; break; // islessequal
    case 0xc5: ST = (int64_t)ST >= 0 ? 1 : 0; ip += 1; break; // isgreaterequal
    case 0xa0: REG1 += REG2; ip += 2; break; // add
    case 0xa1: REG1 -= REG2; ip += 2; break; // sub
    case 0xa2: REG1 *= REG2; ip += 2; break; // mul
    case 0xa3: REG1 /= REG2; ip += 2; break; // div
    case 0xa4: REG1 %= REG2; ip += 2; break; // rem
    case 0xb0: REG1 &= REG2; ip += 2; break; // and
    case 0xb1: REG1 |= REG2; ip += 2; break; // or
    case 0xb2: REG1 ^= REG2; ip += 2; break; // xor
    case 0xb3: REG1 = ~REG1; ip += 2; break; // not
    default: dump_and_panic("invalid instruction"); return;
  }
  if (TRACE_INSTRUCTIONS) {
    printf("ran %x -> ", opcode);
    dump_reg();
  }
}

void run(void) {
  for (int i = 0; 1; i++) {
    // dump_reg();
    // printf("Memory:");
    // for (int i = 0x18650; i < MEMORY_SIZE; i++)
    //   printf("%c%02x", i == SP ? '|' : ' ', mem[i]);
    // printf("\n");
    run_single();
  }
}

void syscall_none(void) { dump_and_panic("invalid syscall number"); }
void syscall_exit(void) {
  if (TRACE_SYSCALLS) printf("syscall exit(%ld)\n", REGA);
  printf("exited with %ld\n", REGA);
  exit(REGA);
}
void syscall_print(void) {
  if (TRACE_SYSCALLS) printf("syscall print(%lx, %ld)\n", REGA, REGB);
  for (int i = 0; i < REGB; i++) printf("%c", mem[REGA + i]);
  if (TRACE_CALLS || TRACE_SYSCALLS) printf("\n");
}
void syscall_log(void) {
  if (TRACE_SYSCALLS) printf("syscall log(%lx, %ld)\n", REGA, REGB);
  for (int i = 0; i < REGB; i++) fprintf(stderr, "%c", mem[REGA + i]);
  if (TRACE_CALLS || TRACE_SYSCALLS) fprintf(stderr, "\n");
}
void syscall_create(void) {
  if (TRACE_SYSCALLS) printf("syscall create(%lx, %ld)\n", REGA, REGB);
  char filename[REGB + 1];
  for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
  filename[REGB] = 0;
  REGA = (Word)fopen(filename, "w+");
}
void syscall_open_reading(void) {
  if (TRACE_SYSCALLS) printf("syscall open_reading(%lx, %ld)\n", REGA, REGB);
  char filename[REGB + 1];
  for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
  filename[REGB] = 0;
  printf("opening filename %s\n", filename);
  REGA = (Word)fopen(filename, "r");
}
void syscall_open_writing(void) {
  if (TRACE_SYSCALLS) printf("syscall open_writing(%lx, %ld)\n", REGA, REGB);
  char filename[REGB + 1];
  for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
  filename[REGB] = 0;
  REGA = (Word)fopen(filename, "w+");
}
void syscall_read(void) {
  if (TRACE_SYSCALLS) printf("syscall read(%ld, %lx, %ld)\n", REGA, REGB, REGC);
  REGA = fread(mem + REGB, 1, REGC, (FILE*)(mem + REGA));
}
void syscall_write(void) {
  if (TRACE_SYSCALLS)
    printf("syscall write(%ld, %lx, %ld)\n", REGA, REGB, REGC);
  // TODO: assert that this worked
  fwrite(mem + REGB, 1, REGC, (FILE*)(mem + REGA));
}
void syscall_close(void) {
  if (TRACE_SYSCALLS) printf("syscall close(%ld)\n", REGA);
  // TODO: assert that this worked
  fclose((FILE*)(mem + REGA));
}

void init_syscalls(void) {
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

  init_vm(bin, len, argc, argv);
  run();
}
