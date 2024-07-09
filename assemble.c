#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define Char char
#define Pos size_t
#define Byte uint8_t
#define Word uint64_t

#define bool Byte
#define true (0 == 0)
#define false !true

int min(int a, int b) { return a < b ? a : b; }
int max(int a, int b) { return a > b ? a : b; }

typedef struct {
  Byte* bytes;
  Pos len;
} Str;

Str str(Char* c_str) {
  Str s;
  s.bytes = c_str;
  s.len = 0;
  while (c_str[s.len] != 0) s.len++;
  return s;
}
Str substr(Str this, Pos start, Pos end) {
  Str s;
  s.bytes = this.bytes + start;
  s.len = end - start;
  return s;
}
bool starts_with(Str this, Str other) {
  if (this.len < other.len) return false;
  for (Pos i = 0; i < other.len; i++)
    if (this.bytes[i] != other.bytes[i]) return false;
  return true;
}
bool strequal(Str this, Str other) {
  if (this.len != other.len) return false;
  return starts_with(this, other);
}

void print_str(Str str) {
  for (Pos i = 0; i < str.len; i++) fprintf(stderr, "%c", str.bytes[i]);
}

typedef struct { Byte* data; Pos len; Pos cap; } Bytes;
Bytes make_bytes(void) {
  Bytes vec;
  vec.data = malloc(8);
  vec.len = 0;
  vec.cap = 8;
  return vec;
}
void push_to_bytes(Bytes* vec, Byte byte) {
  if (vec->len == vec->cap) {
    vec->cap *= 2;
    vec->data = realloc(vec->data, vec->cap);
  }
  vec->data[vec->len] = byte;
  vec->len++;
}

bool is_whitespace(Char c) { return c == ' ' || c == '\n'; }
bool is_num(Char c) { return c >= '0' && c <= '9'; }
bool is_name(Char c) { return !is_whitespace(c) && c != ':'; }

// The parser.

Byte* recipe;
int recipe_len;
int cursor = 0;

char current = (char)EOF;
int line = 0;

void panic(Char* message) {
  fprintf(stderr, "Line %d: %s\n", line, message);
  exit(1);
}

bool is_at_end(void) { return cursor >= recipe_len; }
void advance(void) { current = recipe[cursor]; cursor++; }
void consume_whitespace() {
  while (!is_at_end()) {
    if (current == ' ') advance();
    else if (current == '\n') {
      advance();
      line++;
    } else if (current == '|') {
      while (!is_at_end() && current != '\n') advance();
    } else
      break;
  }
}
bool consume_prefix(char prefix) {
  consume_whitespace();
  if (current != prefix) return false;
  advance();
  return true;
}
Str parse_str(void) {
  if (!consume_prefix('\"')) panic("Expected a string.");
  Bytes str = make_bytes();
  while (!is_at_end() && current != '"') {
    push_to_bytes(&str, current);
    advance();
  }
  if (!consume_prefix('\"')) panic("Expected end of string.");
  Str str_str;
  str_str.bytes = str.data;
  str_str.len = str.len;
  return str_str;
}
Str parse_name(void) {
  consume_whitespace();
  if (current == '\"') return parse_str();
  bool parsed_something = false;
  Bytes name = make_bytes();
  while (!is_at_end() && is_name(current)) {
    parsed_something = true;
    push_to_bytes(&name, current);
    advance();
  }
  if (!parsed_something) panic("Expected a name.");
  Str name_str;
  name_str.bytes = name.data;
  name_str.len = name.len;
  return name_str;
}
Word parse_digits(Word radix) {
  bool parsed_something = false;
  Word num = 0;
  while (!is_at_end()) {
    Char c = current;
    if (c >= '0' && c < '0' + min(radix, 10))
      num = num * radix + c - '0';
    else if (radix >= 10 && c >= 'a' && c < 'a' + min(radix - 10, 26))
      num = num * radix + c - 'a' + 10;
    else if (c != '_') break;
    advance();
    parsed_something = true;
  }
  if (!parsed_something) panic("Expected a number.");
  return num;
}
Word parse_num(void) {
  consume_whitespace();
  if (consume_prefix('0')) {
    if (is_whitespace(current)) return 0;
    if (consume_prefix('b')) return parse_digits(2);
    if (consume_prefix('x')) return parse_digits(16);
    panic("Expected number radix char (b or x).");
  }
  return parse_digits(10);
}

typedef enum { reg_sp, reg_st, reg_a, reg_b, reg_c, reg_d, reg_e, reg_f } Reg;
Reg parse_reg(void) {
  Str n = parse_name();
  if (strequal(n, str("sp"))) return reg_sp;
  if (strequal(n, str("st"))) return reg_st;
  if (strequal(n, str("a"))) return reg_a;
  if (strequal(n, str("b"))) return reg_b;
  if (strequal(n, str("c"))) return reg_c;
  if (strequal(n, str("d"))) return reg_d;
  if (strequal(n, str("e"))) return reg_e;
  if (strequal(n, str("f"))) return reg_f;
  panic("Expected a register.");
}

Byte to_bits(Reg reg) {
  switch (reg) {
    case reg_sp: return 0b0000;
    case reg_st: return 0b0001;
    case reg_a: return 0b0010;
    case reg_b: return 0b0011;
    case reg_c: return 0b0100;
    case reg_d: return 0b0101;
    case reg_e: return 0b0110;
    case reg_f: return 0b0111;
    default: panic("Invalid register.");
  }
}

// Label storage.

Str last_label;

Str globalize_label(Str label) {
  int num_dots = 0;
  while (num_dots < label.len && label.bytes[num_dots] == '.') num_dots++;
  label = substr(label, num_dots, label.len);
  if (num_dots == 0) return label;
  int shared_prefix = 0;
  while (true) {
    if (shared_prefix >= last_label.len) {
      if (num_dots == 1) break;
      panic("Label has too many dots at the beginning.");
    }
    if (last_label.bytes[shared_prefix] == '.') {
      num_dots--;
      if (num_dots == 0) break;
    }
    shared_prefix++;
  }
  Str global;
  global.bytes = malloc(shared_prefix + 1 + label.len);
  for (int i = 0; i < shared_prefix; i++) global.bytes[i] = last_label.bytes[i];
  global.bytes[shared_prefix] = '.';
  for (int i = 0; i < label.len; i++)
    global.bytes[shared_prefix + 1 + i] = label.bytes[i];
  global.len = shared_prefix + 1 + label.len;
  return global;
}

typedef struct { Str label; Pos pos; } LabelAndPos;
typedef struct { LabelAndPos* entries; Pos len; Pos cap; } Labels;
Labels labels;

Labels init_labels(void) {
  labels.entries = malloc(8 * sizeof(LabelAndPos));
  labels.len = 0;
  labels.cap = 8;
}
void push_label(Str label, Pos pos) {
  if (labels.len == labels.cap) {
    labels.cap *= 2;
    labels.entries = realloc(labels.entries, labels.cap * sizeof(LabelAndPos));
  }
  labels.entries[labels.len].label = label;
  labels.entries[labels.len].pos = pos;
  labels.len++;
}
Word find_label(Str label) {
  for (Pos i = 0; i < labels.len; i++)
    if (strequal(label, labels.entries[i].label))
      return labels.entries[i].pos;
  return -1;
}

// The output.

Bytes output;
Pos start_of_section = 0; // labels are relative to this

// Patches.

typedef struct { Str label; Pos where; } Patch;
typedef struct { Patch* items; Pos cap; Pos len; } Patches;
Patches patches;

Patches init_patches(void) {
  patches.items = malloc(8 * sizeof(Patch));
  patches.cap = 8;
  patches.len = 0;
  return patches;
}
void push_patch(Patch patch) {
  if (patches.len == patches.cap) {
    patches.cap *= 2;
    patches.items = realloc(patches.items, patches.cap * sizeof(LabelAndPos));
  }
  patches.items[patches.len] = patch;
  patches.len++;
}
void overwrite_word(Pos pos, Word word);
void fix_patches() {
  for (int i = 0; i < patches.len; i++) {
    Patch patch = patches.items[i];
    Pos target = find_label(patch.label);
    if (target == -1) {
      fprintf(stderr, "Patching label \"");
      print_str(patch.label);
      fprintf(stderr, "\".\n");
      panic("Label not defined.");
    }
    overwrite_word(patch.where, target);
  }
}

// The output binary.

void emit_byte(Byte byte) {
  push_to_bytes(&output, byte);
}
void emit_word(Word word) {
  emit_byte(word & 0xff);
  emit_byte(word >> 8 & 0xff);
  emit_byte(word >> 16 & 0xff);
  emit_byte(word >> 24 & 0xff);
  emit_byte(word >> 32 & 0xff);
  emit_byte(word >> 40 & 0xff);
  emit_byte(word >> 48 & 0xff);
  emit_byte(word >> 56 & 0xff);
}
void overwrite_word(Pos pos, Word word) {
  output.data[pos + 0] = word & 0xff;
  output.data[pos + 1] = word >> 8 & 0xff;
  output.data[pos + 2] = word >> 16 & 0xff;
  output.data[pos + 3] = word >> 24 & 0xff;
  output.data[pos + 4] = word >> 32 & 0xff;
  output.data[pos + 5] = word >> 40 & 0xff;
  output.data[pos + 6] = word >> 48 & 0xff;
  output.data[pos + 7] = word >> 56 & 0xff;
}
void emit_str(Str str) {
  for (int i = 0; i < str.len; i++) emit_byte(str.bytes[i]);
}
void emit_reg(Reg reg) { emit_byte(to_bits(reg)); }
void emit_regs(Reg first, Reg second) {
  emit_byte(to_bits(first) + (to_bits(second) << 4));
}
void emit_label_ref(Str label) {
  label = globalize_label(label);
  Patch patch;
  patch.label = label;
  patch.where = output.len;
  push_patch(patch);
  emit_word(0);
}
void define_label(Str label) {
  label = globalize_label(label);

  last_label = label;
  Pos pos = output.len - start_of_section;
  push_label(label, pos);
}

void main(int argc, char** argv) {
  FILE* file = fopen(argv[1], "rb");
  if (file == NULL) panic("couldn't open file");
  fseek(file, 0L, SEEK_END);
  recipe_len = ftell(file);
  rewind(file);
  recipe = (Byte*)malloc(recipe_len + 1);
  if (recipe == NULL) panic("out of memory");
  size_t read = fread(recipe, sizeof(char), recipe_len, file);
  if (read != recipe_len) panic("file size changed after fseek");
  recipe[read] = 0;
  fclose(file);

  output = make_bytes();
  last_label = str("");
  init_labels();
  init_patches();
  advance();

  emit_str(str("soil"));

  // Byte code section
  emit_byte(0);  // type: byte code
  Pos pointer_to_byte_code_section_len = output.len;
  emit_word(0); // len of byte code

  start_of_section = output.len;
  while (true) {
    consume_whitespace();
    if (is_at_end()) break;

    Str name = parse_name();

    bool is_label = consume_prefix(':');
    if (is_label) {
      define_label(name);
    } else {
      Str command = name;

      #define EMIT_OP(opcode) { emit_byte(opcode); }
      #define EMIT_OP_REG(opcode) { emit_byte(opcode); emit_reg(parse_reg()); }
      #define EMIT_OP_REG_REG(opcode) { emit_byte(opcode); \
        Reg a = parse_reg(); Reg b = parse_reg(); emit_regs(a, b); }
      #define EMIT_OP_REG_BYTE(opcode) { emit_byte(opcode); \
        emit_reg(parse_reg()); emit_byte(parse_num()); }
      #define EMIT_OP_REG_WORD(opcode) { emit_byte(opcode); \
        emit_reg(parse_reg()); consume_whitespace(); \
        if (is_num(current)) emit_word(parse_num()); else emit_label_ref(parse_name()); }
      #define EMIT_OP_BYTE(opcode) { emit_byte(opcode); emit_byte(parse_num()); }
      #define EMIT_OP_WORD(opcode) { emit_byte(opcode); consume_whitespace(); \
        if (is_num(current)) emit_word(parse_num()); else emit_label_ref(parse_name()); }
      #define EMIT_OP_LABEL(opcode) { emit_byte(opcode); emit_label_ref(parse_name()); }

      if (strequal(command, str("nop"))) EMIT_OP(0x00)
      else if (strequal(command, str("panic"))) EMIT_OP(0xe0)
      else if (strequal(command, str("trystart"))) EMIT_OP_WORD(0xe1)
      else if (strequal(command, str("tryend"))) EMIT_OP(0xe2)
      else if (strequal(command, str("move"))) EMIT_OP_REG_REG(0xd0)
      else if (strequal(command, str("movei"))) EMIT_OP_REG_WORD(0xd1)
      else if (strequal(command, str("moveib"))) EMIT_OP_REG_BYTE(0xd2)
      else if (strequal(command, str("load"))) EMIT_OP_REG_REG(0xd3)
      else if (strequal(command, str("loadb"))) EMIT_OP_REG_REG(0xd4)
      else if (strequal(command, str("store"))) EMIT_OP_REG_REG(0xd5)
      else if (strequal(command, str("storeb"))) EMIT_OP_REG_REG(0xd6)
      else if (strequal(command, str("push"))) EMIT_OP_REG(0xd7)
      else if (strequal(command, str("pop"))) EMIT_OP_REG(0xd8)
      else if (strequal(command, str("jump"))) EMIT_OP_LABEL(0xf0)
      else if (strequal(command, str("cjump"))) EMIT_OP_LABEL(0xf1)
      else if (strequal(command, str("call"))) EMIT_OP_WORD(0xf2)
      else if (strequal(command, str("ret"))) EMIT_OP(0xf3)
      else if (strequal(command, str("syscall"))) EMIT_OP_BYTE(0xf4)
      else if (strequal(command, str("cmp"))) EMIT_OP_REG_REG(0xc0)
      else if (strequal(command, str("isequal"))) EMIT_OP(0xc1)
      else if (strequal(command, str("isless"))) EMIT_OP(0xc2)
      else if (strequal(command, str("isgreater"))) EMIT_OP(0xc3)
      else if (strequal(command, str("islessequal"))) EMIT_OP(0xc4)
      else if (strequal(command, str("isgreaterequal"))) EMIT_OP(0xc5)
      else if (strequal(command, str("isnotequal"))) EMIT_OP(0xc6)
      else if (strequal(command, str("fcmp"))) EMIT_OP_REG_REG(0xc7)
      else if (strequal(command, str("fisequal"))) EMIT_OP(0xc8)
      else if (strequal(command, str("fisless"))) EMIT_OP(0xc9)
      else if (strequal(command, str("fisgreater"))) EMIT_OP(0xca)
      else if (strequal(command, str("fislessequal"))) EMIT_OP(0xcb)
      else if (strequal(command, str("fisgreaterequal"))) EMIT_OP(0xcc)
      else if (strequal(command, str("fisnotequal"))) EMIT_OP(0xcd)
      else if (strequal(command, str("inttofloat"))) EMIT_OP_REG(0xce)
      else if (strequal(command, str("floattoint"))) EMIT_OP_REG(0xcf)
      else if (strequal(command, str("add"))) EMIT_OP_REG_REG(0xa0)
      else if (strequal(command, str("sub"))) EMIT_OP_REG_REG(0xa1)
      else if (strequal(command, str("mul"))) EMIT_OP_REG_REG(0xa2)
      else if (strequal(command, str("div"))) EMIT_OP_REG_REG(0xa3)
      else if (strequal(command, str("rem"))) EMIT_OP_REG_REG(0xa4)
      else if (strequal(command, str("fadd"))) EMIT_OP_REG_REG(0xa5)
      else if (strequal(command, str("fsub"))) EMIT_OP_REG_REG(0xa6)
      else if (strequal(command, str("fmul"))) EMIT_OP_REG_REG(0xa7)
      else if (strequal(command, str("fdiv"))) EMIT_OP_REG_REG(0xa8)
      else if (strequal(command, str("and"))) EMIT_OP_REG_REG(0xb0)
      else if (strequal(command, str("or"))) EMIT_OP_REG_REG(0xb1)
      else if (strequal(command, str("xor"))) EMIT_OP_REG_REG(0xb2)
      else if (strequal(command, str("not"))) EMIT_OP_REG(0xb3)
      else if (strequal(command, str("@data"))) break;
      else {
        fprintf(stderr, "Command is \"");
        for (int i = 0; i < command.len; i++)
          fprintf(stderr, "%c", command.bytes[i]);
        fprintf(stderr, "\".\n");
        panic("Unknown command.");
      }
    }
  }

  int num_labels_in_byte_code_section = labels.len;

  int byte_code_len = output.len - start_of_section;
  overwrite_word(pointer_to_byte_code_section_len, byte_code_len);

  // Initial memory section
  emit_byte(1);  // type: initial memory
  Pos pointer_to_memory_section_len = output.len;
  emit_word(0);  // len of initial memory

  start_of_section = output.len;
  while (true) {
    consume_whitespace();
    if (is_at_end()) break;

    Str name = parse_name();

    bool is_label = consume_prefix(':');
    if (is_label) {
      define_label(name);
    } else {
      Str command = name;

      if (strequal(command, str("str"))) {
        Str str = parse_str();
        for (int i = 0; i < str.len; i++) emit_byte(str.bytes[i]);
      }
      else if (strequal(command, str("byte"))) emit_byte(parse_num());
      else if (strequal(command, str("word"))) {
        if (is_num(current)) emit_word(parse_num()); else emit_label_ref(parse_name());
      } else {
        fprintf(stderr, "Command is \"");
        for (int i = 0; i < command.len; i++)
          fprintf(stderr, "%c", command.bytes[i]);
        fprintf(stderr, "\".\n");
        panic("Unknown data command.");
      }
    }
  }

  if (!is_at_end()) panic("Didn't parse the entire input.");

  fix_patches();
  labels.len = num_labels_in_byte_code_section;

  int memory_len = output.len - start_of_section;
  overwrite_word(pointer_to_memory_section_len, memory_len);

  emit_byte(3);  // type: debug info
  Pos pointer_to_debug_info_len = output.len;
  emit_word(0);  // len of debug info
  Pos start_of_debug_info = output.len;
  emit_word(labels.len); // number of labels
  for (Pos i = 0; i < labels.len; i++) {
    LabelAndPos label_and_pos = labels.entries[i];
    emit_word(label_and_pos.pos);
    emit_word(label_and_pos.label.len);
    for (int j = 0; j < label_and_pos.label.len; j++)
      emit_byte(label_and_pos.label.bytes[j]);
  }
  int debug_info_len = output.len - start_of_debug_info;
  overwrite_word(pointer_to_debug_info_len, debug_info_len);

  int i = 0;
  for (i = strlen(argv[1]); i > 0 && argv[1][i - 1] != '.'; i--);
  argv[1][i + 0] = 's';
  argv[1][i + 1] = 'o';
  argv[1][i + 2] = 'i';
  argv[1][i + 3] = 'l';
  argv[1][i + 4] = '\0';
  FILE* outfile = fopen(argv[1], "w+");
  if (outfile == NULL) panic("couldn't open file");
  fwrite(output.data, 1, output.len, outfile);
  fclose(outfile);

  printf("Written to %s.\n", argv[1]);

  // for (int i = 0; i < output.len; i++) printf("%c", output.data[i]);
  // printf("%02x ", output.data[i]);

  exit(0);
}
