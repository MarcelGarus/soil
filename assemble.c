#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

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
  for (Pos i = 0; i < str.len; i++) printf("%c", str.bytes[i]);
}

void panic(Char* message) {
  printf("%s\n", message);
  exit(1);
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
bool is_name(Char c) {
  return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' ||
         c >= '0' && c <= '9' || c == '_' || c == '.';
}

// The parser.
char current = (char)EOF;
int line = 0;

bool is_at_end(void) { return current == (char)EOF; }
void advance(void) { current = getchar(); }
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
Str parse_name(void) {
  consume_whitespace();
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
    if (c >= '0' && c <= '0' + min(radix, 10))
      num = num * radix + c - '0';
    else if (radix >= 10 && c >= 'a' && c <= 'a' + min(radix - 10, 26))
      num = num * radix + c - 'a';
    else if (c != '_') break;
    advance();
    parsed_something = true;
  }
  if (!parsed_something) panic("Expected a number.");
  return num;
}
Word parse_num(void) {
  consume_whitespace();
  if (consume_prefix('b')) return parse_digits(2);
  if (consume_prefix('x')) return parse_digits(16);
  return parse_digits(10);
}
typedef enum { reg_ip, reg_sp, reg_st, reg_a, reg_b, reg_c, reg_d, reg_e } Reg;
Reg parse_reg(void) {
  Str n = parse_name();
  if (strequal(n, str("ip"))) return reg_ip;
  if (strequal(n, str("sp"))) return reg_sp;
  if (strequal(n, str("st"))) return reg_st;
  if (strequal(n, str("a"))) return reg_a;
  if (strequal(n, str("b"))) return reg_b;
  if (strequal(n, str("c"))) return reg_c;
  if (strequal(n, str("d"))) return reg_d;
  if (strequal(n, str("e"))) return reg_e;
  panic("Expected a register.");
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

Byte to_bits(Reg reg) {
  switch (reg) {
    case reg_ip: return 0b0000;
    case reg_sp: return 0b0001;
    case reg_st: return 0b0010;
    case reg_a: return 0b0011;
    case reg_b: return 0b0100;
    case reg_c: return 0b0101;
    case reg_d: return 0b0110;
    case reg_e: return 0b0111;
    default: panic("Invalid register.");
  }
}

typedef struct { Str label; Pos pos; } LabelAndPos;
typedef struct { LabelAndPos* entries; Pos len; Pos cap; } Labels;
Labels make_labels(void) {
  Labels labels;
  labels.entries = malloc(8 * sizeof(LabelAndPos));
  labels.len = 0;
  labels.cap = 8;
  return labels;
}
void push_to_labels(Labels* labels, Str label, Pos pos) {
  if (labels->len == labels->cap) {
    labels->cap *= 2;
    labels->entries = realloc(labels->entries, labels->cap * sizeof(LabelAndPos));
  }
  labels->entries[labels->len].label = label;
  labels->entries[labels->len].pos = pos;
  labels->len++;
}
Word find_in_labels(Labels* labels, Str label) {
  for (Pos i = 0; i < labels->len; i++)
    if (strequal(label, labels->entries[i].label))
      return labels->entries[i].pos;
  return -1;
}

typedef struct { Str label; Pos where; Pos relative_to; } Backpatch;
typedef struct { Backpatch* items; Pos cap; Pos start; Pos end; } Backpatches;
Backpatches make_backpatches(void) {
  Backpatches backpatches;
  backpatches.items = malloc(8 * sizeof(Backpatch));
  backpatches.cap = 8;
  backpatches.start = 0;
  backpatches.end = 0;
  return backpatches;
}
Pos len_of_backpatches(Backpatches* b) {
  return b->end >= b->start ? (b->end - b->start) : (b->start + b->cap - b->end);
}
void reserve_backpatches(Backpatches* b, Pos size) {
  if (b->cap >= size) return;
  Pos len = len_of_backpatches(b);
  Backpatch* new_items = malloc(size * sizeof(Backpatch));
  if (b->start <= b->end) {
    for (Pos i = 0; i < len; i++) new_items[i] = b->items[i];
  } else {
    for (Pos i = 0; i < b->cap - b->start; i++) new_items[i] = b->items[b->start + i];
    for (Pos i = 0; i < b->start; i++) new_items[b->cap - b->start + i] = b->items[i];
  }
  b->start = 0;
  b->end = len;
  free(b->items);
  b->items = new_items;
}
void push_to_backpatches(Backpatches* b, Backpatch backpatch) {
  if (b->cap == len_of_backpatches(b))
    reserve_backpatches(b, len_of_backpatches(b) * 2);
  b->items[b->end] = backpatch;
  b->end = (b->end + 1) % b->cap;
}
Backpatch pop_from_backpatches(Backpatches* b) {
  if (len_of_backpatches(b) == 0) panic("Popped from empty backpatches.");
  Backpatch backpatch = b->items[b->start];
  b->start = (b->start + 1) % b->cap;
  return backpatch;
}
Backpatch get_from_backpatches(Backpatches* b, Pos index) {
  return b->items[(index + b->start) % b->cap];
}

Bytes output;
Str last_label;
Labels labels;
Backpatches backpatches;

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
  for (int i = 0; i < shared_prefix; i++)
    global.bytes[i] = last_label.bytes[i];
  global.bytes[shared_prefix] = '.';
  for (int i = 0; i < label.len; i++)
    global.bytes[shared_prefix + 1 + i] = label.bytes[i];
  global.len = shared_prefix + 1 + label.len;
  return global;
}
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
void emit_label_ref(Str label, int relative_to) {
  label = globalize_label(label);

  Word pos = find_in_labels(&labels, label);
  if (pos == -1) {
    Backpatch b;
    b.label = label;
    b.where = output.len;
    b.relative_to = relative_to;
    push_to_backpatches(&backpatches, b);
    emit_word(0);
  } else {
    emit_word(pos - relative_to);
  }
}
void define_label(Str label) {
  label = globalize_label(label);

  last_label = label;
  Pos pos = output.len;
  push_to_labels(&labels, label, pos);

  print_str(label);
  printf(": %ld\n", pos);
  while (len_of_backpatches(&backpatches) > 0) {
    Backpatch first = get_from_backpatches(&backpatches, 0);
    if (strequal(first.label, label)) {
      pop_from_backpatches(&backpatches);
      overwrite_word(first.where, pos - first.relative_to);
    } else break;
  }
}

void main(int argc, char** argv) {
  printf("assembling\n");
  output = make_bytes();
  last_label = str("");
  labels = make_labels();
  backpatches = make_backpatches();
  advance();

  emit_str(str("soil"));
  emit_byte(2); // num headers: devices, machine code

  emit_byte(2); // devices
  Pos pointer_to_device_section = output.len;
  emit_word(0);

  emit_byte(3); // machine code
  Pos pointer_to_machine_code_section = output.len;
  emit_word(0);

  Str devices[256];
  for (int i = 0; i < 256; i++) devices[i].len = 0;
  while (consume_prefix('@')) {
    int index = parse_num();
    Str name = parse_str();
    devices[index] = name;
  }
  int last_device = 256;
  while (last_device > 0 && devices[last_device - 1].len == 0) last_device--;
  Pos device_hints[256];
  for (int i = 0; i < last_device; i++) {
    device_hints[i] = output.len;
    emit_str(devices[i]);
  }
  overwrite_word(pointer_to_device_section, output.len);
  emit_byte(last_device);
  for (int i = 0; i < last_device; i++) {
    emit_word(device_hints[i]);
    emit_byte(devices[i].len);
  }

  overwrite_word(pointer_to_machine_code_section, output.len);
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
      #define EMIT_OP_REG(opcode) { \
        emit_byte(opcode); \
        emit_reg(parse_reg()); }
      #define EMIT_OP_REG_REG(opcode) { \
        emit_byte(opcode); \
        emit_regs(parse_reg(), parse_reg()); }
      #define EMIT_OP_REG_BYTE(opcode) { \
        emit_byte(opcode); \
        emit_reg(parse_reg()); \
        emit_byte(parse_num()); }
      #define EMIT_OP_REG_WORD(opcode) { \
        emit_byte(opcode); \
        emit_reg(parse_reg()); \
        emit_word(parse_num()); }
      #define EMIT_OP_REG_LABEL(opcode) { \
        Pos base = output.len; \
        emit_byte(opcode); \
        emit_reg(parse_reg()); \
        emit_label_ref(parse_name(), base); }
      #define EMIT_OP_BYTE(opcode) { \
        emit_byte(opcode); \
        emit_byte(parse_num()); }
      #define EMIT_OP_WORD(opcode) { \
        emit_byte(opcode); \
        emit_word(parse_num()); }
      #define EMIT_OP_LABEL(opcode) { \
        Pos base = output.len; \
        emit_byte(opcode); \
        emit_label_ref(parse_name(), base); }

      if (strequal(command, str("nop"))) EMIT_OP(0x00)
      else if (strequal(command, str("panic"))) EMIT_OP(0xe0)
      else if (strequal(command, str("move"))) {
        printf("It's a move.\n");
        EMIT_OP_REG_REG(0xd0)
      }
      else if (strequal(command, str("movei"))) EMIT_OP_REG_WORD(0xd1)
      else if (strequal(command, str("moveib"))) EMIT_OP_REG_BYTE(0xd2)
      else if (strequal(command, str("load"))) EMIT_OP_REG_REG(0xd3)
      else if (strequal(command, str("loadb"))) EMIT_OP_REG_REG(0xd4)
      else if (strequal(command, str("store"))) EMIT_OP_REG_REG(0xd5)
      else if (strequal(command, str("storeb"))) EMIT_OP_REG_REG(0xd6)
      else if (strequal(command, str("push"))) EMIT_OP_REG(0xd7)
      else if (strequal(command, str("pop"))) EMIT_OP_REG(0xd8)
      else if (strequal(command, str("jump"))) EMIT_OP_LABEL(0xf0)
      else if (strequal(command, str("cjump"))) EMIT_OP_REG_LABEL(0xf1)
      else if (strequal(command, str("call"))) EMIT_OP_WORD(0xf2)
      else if (strequal(command, str("ret"))) EMIT_OP(0xf3)
      else if (strequal(command, str("devicecall"))) EMIT_OP_BYTE(0xf4)
      else if (strequal(command, str("cmp"))) EMIT_OP_BYTE(0xc0)
      else if (strequal(command, str("isequal"))) EMIT_OP(0xc1)
      else if (strequal(command, str("isless"))) EMIT_OP(0xc2)
      else if (strequal(command, str("isgreater"))) EMIT_OP(0xc3)
      else if (strequal(command, str("islessequal"))) EMIT_OP(0xc4)
      else if (strequal(command, str("isgreaterequal"))) EMIT_OP(0xc5)
      else if (strequal(command, str("add"))) EMIT_OP_REG_REG(0xa0)
      else if (strequal(command, str("sub"))) EMIT_OP_REG_REG(0xa1)
      else if (strequal(command, str("mul"))) EMIT_OP_REG_REG(0xa2)
      else if (strequal(command, str("div"))) EMIT_OP_REG_REG(0xa3)
      else if (strequal(command, str("and"))) EMIT_OP_REG_REG(0xb0)
      else if (strequal(command, str("or"))) EMIT_OP_REG_REG(0xb1)
      else if (strequal(command, str("xor"))) EMIT_OP_REG_REG(0xb2)
      else if (strequal(command, str("negate"))) EMIT_OP_REG(0xb3)
      else {
        printf("Command is ");
        for (int i = 0; i < command.len; i++)
          printf("%c", command.bytes[i]);
        printf(" (len %ld)\n", command.len);
        panic("Unknown command.");
      }
    }
  }

  if (!is_at_end()) panic("Didn't parse the entire input.");
  printf("Bytes: ");
  for (int i = 0; i < output.len; i++)
    printf("%02x ", output.data[i]);
  printf("\n");

  exit(0);
}
