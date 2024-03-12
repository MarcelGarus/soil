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

bool is_whitespace(Char c) { return c == ' ' || c == '\n'; }
bool is_name(Char c) {
  return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' ||
         c >= '0' && c <= '9' || c == '_' || c == '.';
}

typedef struct {
  Str input;
  Pos cursor;
} Parser;

Parser make_parser(Str input) {
  Parser p;
  p.input = input;
  p.cursor = 0;
  return p;
}
bool is_at_end(Parser* this) { return this->cursor >= this->input.len; }
char current(Parser* this) { return this->input.bytes[this->cursor]; }
Str rest(Parser* this) {
  return substr(this->input, this->cursor, this->input.len);
}
void advance_by(Parser* this, Pos n) { this->cursor += n; }
void advance(Parser* this) { advance_by(this, 1); }
void consume_whitespace(Parser* this) {
  while (!is_at_end(this)) {
    Char c = current(this);
    if (is_whitespace(c)) {
      advance(this);
    } else if (c == '|') {
      while (!is_at_end(this) && current(this) != '\n') advance(this);
    } else break;
  }
}
bool consume_prefix(Parser* this, Str prefix) {
  consume_whitespace(this);
  if (!starts_with(rest(this), prefix)) return false;
  advance_by(this, prefix.len);
  return true;
}
bool consume_keyword(Parser* this, Str keyword) {
  consume_whitespace(this);
  if (!starts_with(rest(this), keyword)) return false;
  if (rest(this).len > keyword.len &&
      !is_name(rest(this).bytes[keyword.len])) return false;
  advance_by(this, keyword.len);
  return true;
}
Str parse_name(Parser* this) {
  consume_whitespace(this);
  Pos start = this->cursor;
  while (!is_at_end(this) && is_name(current(this))) advance(this);
  Pos end = this->cursor;
  if (start == end) panic("Expected a name.");
  return substr(this->input, start, end);
}
Word parse_digits(Parser* this, Word radix) {
  Pos start = this->cursor;
  Word num = 0;
  while (!is_at_end(this)) {
    Char c = current(this);
    if (c >= '0' && c <= '0' + min(radix, 10))
      num = num * radix + c - '0';
    else if (radix >= 10 && c >= 'a' && c <= 'a' + min(radix - 10, 26))
      num = num * radix + c - 'a';
    else if (c != '_') break;
    advance(this);
  }
  Pos end = this->cursor;
  if (start == end) panic("Expected a number.");
  return num;
}
Word parse_num(Parser* this) {
  consume_whitespace(this);
  if (consume_prefix(this, str("b"))) return parse_digits(this, 2);
  if (consume_prefix(this, str("x"))) return parse_digits(this, 16);
  return parse_digits(this, 10);
}
typedef enum { reg_ip, reg_sp, reg_st, reg_a, reg_b, reg_c, reg_d, reg_e } Reg;
Reg parse_reg(Parser* this) {
  Str n = parse_name(this);
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
Str parse_str(Parser* this) {
  if (!consume_prefix(this, str("\""))) panic("Expected a string.");
  Pos start = this->cursor;
  while (!is_at_end(this) && current(this) != '"') advance(this);
  Pos end = this->cursor;
  return substr(this->input, start, end);
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

typedef struct { Str label; Pos where; } Backpatch;
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

typedef struct {
  Bytes bytes;
  Str last_label;
  Labels labels;
  Backpatches backpatches;
} Binary;

Binary empty_binary(void) {
  Binary b;
  b.bytes = make_bytes();
  b.last_label = str("");
  b.labels = make_labels();
  b.backpatches = make_backpatches();
  return b;
}
Str globalize_label(Str last, Str label) {
  int num_dots = 0;
  while (num_dots < label.len && label.bytes[num_dots] == '.') num_dots++;
  label = substr(label, num_dots, label.len);
  if (num_dots == 0) return label;
  int shared_prefix = 0;
  while (true) {
    if (shared_prefix >= last.len) {
      if (num_dots == 1) break;
      panic("Label has too many dots at the beginning.");
    }
    if (last.bytes[shared_prefix] == '.') {
      num_dots--;
      if (num_dots == 0) break;
    }
    shared_prefix++;
  }
  Str global;
  global.bytes = malloc(shared_prefix + 1 + label.len);
  for (int i = 0; i < shared_prefix; i++)
    global.bytes[i] = last.bytes[i];
  global.bytes[shared_prefix] = '.';
  for (int i = 0; i < label.len; i++)
    global.bytes[shared_prefix + 1 + i] = label.bytes[i];
  global.len = shared_prefix + 1 + label.len;
  return global;
}
void emit_byte(Binary* this, Byte byte) {
  push_to_bytes(&this->bytes, byte);
}
void emit_word(Binary* this, Word word) {
  emit_byte(this, word & 0xff);
  emit_byte(this, word >> 8 & 0xff);
  emit_byte(this, word >> 16 & 0xff);
  emit_byte(this, word >> 24 & 0xff);
  emit_byte(this, word >> 32 & 0xff);
  emit_byte(this, word >> 40 & 0xff);
  emit_byte(this, word >> 48 & 0xff);
  emit_byte(this, word >> 56 & 0xff);
}
void overwrite_word(Binary* this, Pos pos, Word word) {
  this->bytes.data[pos + 0] = word & 0xff;
  this->bytes.data[pos + 1] = word >> 8 & 0xff;
  this->bytes.data[pos + 2] = word >> 16 & 0xff;
  this->bytes.data[pos + 3] = word >> 24 & 0xff;
  this->bytes.data[pos + 4] = word >> 32 & 0xff;
  this->bytes.data[pos + 5] = word >> 40 & 0xff;
  this->bytes.data[pos + 6] = word >> 48 & 0xff;
  this->bytes.data[pos + 7] = word >> 56 & 0xff;
}
void emit_reg(Binary* this, Reg reg) { emit_byte(this, to_bits(reg)); }
void emit_regs(Binary* this, Reg first, Reg second) {
  emit_byte(this, to_bits(first) + (to_bits(second) << 4));
}
void emit_label_ref(Binary* this, Str label) {
  label = globalize_label(this->last_label, label);

  Word pos = find_in_labels(&this->labels, label);
  if (pos == -1) {
    Backpatch b;
    b.label = label;
    b.where = this->bytes.len;
    push_to_backpatches(&this->backpatches, b);
    emit_word(this, 0);
  } else {
    emit_word(this, pos);
  }
}
void define_label(Binary* this, Str label) {
  label = globalize_label(this->last_label, label);

  this->last_label = label;
  Pos pos = this->bytes.len;
  push_to_labels(&this->labels, label, pos);

  print_str(label);
  printf(": %ld\n", pos);
  while (len_of_backpatches(&this->backpatches) > 0) {
    Backpatch first = get_from_backpatches(&this->backpatches, 0);
    if (strequal(first.label, label)) {
      pop_from_backpatches(&this->backpatches);
      overwrite_word(this, first.where, pos);
    } else break;
  }
}

void assemble(Str input) {
  Str devices[256];
  Binary binary = empty_binary();
  Parser parser = make_parser(input);

  while (consume_keyword(&parser, str("device"))) {
    int index = parse_num(&parser);
    Str name = parse_str(&parser);
  }

  while (true) {
    consume_whitespace(&parser);
    if (is_at_end(&parser)) break;

    Str name = parse_name(&parser);

    bool is_label = consume_prefix(&parser, str(":"));
    if (is_label) {
      define_label(&binary, name);
    } else {
      Str command = name;

      #define EMIT_OP(opcode) { emit_byte(&binary, opcode); }
      #define EMIT_OP_REG(opcode) { \
        emit_byte(&binary, opcode); \
        emit_reg(&binary, parse_reg(&parser)); }
      #define EMIT_OP_REG_REG(opcode) { \
        emit_byte(&binary, opcode); \
        emit_regs(&binary, parse_reg(&parser), parse_reg(&parser)); }
      #define EMIT_OP_REG_BYTE(opcode) { \
        emit_byte(&binary, opcode); \
        emit_reg(&binary, parse_reg(&parser)); \
        emit_byte(&binary, parse_num(&parser)); }
      #define EMIT_OP_REG_WORD(opcode) { \
        emit_byte(&binary, opcode); \
        emit_reg(&binary, parse_reg(&parser)); \
        emit_word(&binary, parse_num(&parser)); }
      #define EMIT_OP_REG_LABEL(opcode) { \
        emit_byte(&binary, opcode); \
        emit_reg(&binary, parse_reg(&parser)); \
        emit_label_ref(&binary, parse_name(&parser)); }
      #define EMIT_OP_BYTE(opcode) { \
        emit_byte(&binary, opcode); \
        emit_byte(&binary, parse_num(&parser)); }
      #define EMIT_OP_WORD(opcode) { \
        emit_byte(&binary, opcode); \
        emit_word(&binary, parse_num(&parser)); }
      #define EMIT_OP_LABEL(opcode) { \
        emit_byte(&binary, opcode); \
        emit_label_ref(&binary, parse_name(&parser)); }

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

  if (!is_at_end(&parser)) panic("Didn't parse the entire input.");
  printf("Bytes: ");
  for (int i = 0; i < binary.bytes.len; i++)
    printf("%02x ", binary.bytes.data[i]);
  printf("\n");
  return;
}

void main(int argc, char** argv) {
  if (argc < 2) panic("Wrong usage.");
  char* path = argv[1];
  printf("Assembling %s.\n", path);

  Bytes input = make_bytes();
  FILE* file = fopen(path, "r");
  if (file == NULL) panic("Couldn't open file.");
  while (true) {
    char c = fgetc(file);
    if (c == EOF) break;
    push_to_bytes(&input, c);
  }
  push_to_bytes(&input, 0);
  fclose(file);

  assemble(str(input.data));

  exit(0);
}
