# Soil

Soil is a bytecode interpreter.
It can run Soil binaries, which are files that end with `.soil`.

Soil is designed to be easy to implement on typical machines.
It has 8 registers and memory.
Side effects happen through *devices* connected to the Soil instance.

TODO: Graphic of the architecture

## Binaries

Soil binaries contain the following information:

- which devices are expected to be available
- the machine code

Upon startup, Soil does the following:

1. Wire up the devices.
2. Load the machine code into memory.
3. Set initial register contents.
   1. the instruction pointer `ip` to the address of the machine code
   2. the stack pointer `sp` to the last memory address
   3. all other registers to zero
4. Start running.

## Registers

Soil has 8 registers, all of which hold 64 bits.

| name | description              |
| ---- | ------------------------ |
| `ip` | instruction pointer      |
| `sp` | stack pointer            |
| `st` | status register          |
| `a`  | general-purpose register |
| `b`  | general-purpose register |
| `c`  | general-purpose register |
| `d`  | general-purpose register |
| `e`  | general-purpose register |

## Instructions

Machine code consists of a sequence of instructions.
All instructions start with a byte containing the opcode, followed by the arguments to the operation.
The following instructions are available:

| opcode | mnemonic       | arg 0         | arg 1        |
| ------ | -------------- | ------------- | ------------ |
|     00 | nop            | -             | -            |
|     e0 | panic          | -             | -            |
|     d0 | move           | to: reg       | from: reg    |
|     d1 | movei          | to: reg       | value: word  |
|     d2 | moveib         | to: reg       | value: byte  |
|     d3 | load           | to: reg       | from: reg    |
|     d4 | loadb          | to: reg       | from: reg    |
|     d5 | store          | to: reg       | from: reg    |
|     d6 | storeb         | to: reg       | from: reg    |
|     d7 | push           | reg: reg      | -            |
|     d8 | pop            | reg: reg      | -            |
|     f0 | jump           | to: word      | -            |
|     f1 | cjump          | cond: reg     | to: word     |
|     f2 | call           | target: word  | -            |
|     f3 | ret            | -             | -            |
|     f4 | devicecall     | device: byte  | -            |
|     c0 | cmp            | left: reg     | right: reg   |
|     c1 | isequal        | -             | -            |
|     c2 | isless         | -             | -            |
|     c3 | isgreater      | -             | -            |
|     c4 | islessequal    | -             | -            |
|     c5 | isgreaterequal | -             | -            |
|     a0 | add            | to: reg       | from: reg    |
|     a1 | sub            | to: reg       | from: reg    |
|     a2 | mul            | to: reg       | from: reg    |
|     a3 | div            | dividend: reg | divisor: reg |
|     b0 | and            | to: reg       | from: reg    |
|     b1 | or             | to: reg       | from: reg    |
|     b2 | xor            | to: reg       | from: reg    |
|     b3 | negate         | to: reg       | -            |

- `nop`: Does nothing.
- `panic`: Panics with a message. Takes the message length from `a` and the pointer to the message from `b`.
- `move <to:reg> <from:reg>`: Moves a value between two registers.
- `movei <to:reg> <value:word>`: Moves a 64-bit immediate value into a register.
- `moveib <to:reg> <from:reg>`: Moves an 8-bit immediate value into a register.
- `load <to:reg> <from:reg>`: Interprets the content of the `from` register as an address and moves the 64 bits at that address into the `to` register.
- `loadb <to:reg> <from:reg>`: Interprets the content of the `from` register as an address and moves the 8 bits at that address into the `to` register.
- `store <to:reg> <from:reg>`: Interprets the content of the `to` register as an address and moves the content of the `from` register to that address.
- `storeb <to:reg> <from:reg>`: Interprets the content of the `to` register as an address and moves the lower 8 bits of the `from` register to that address.
- `push <reg:reg>`: Sugar for `sub sp 8`, `store sp reg`.
- `pop <reg:reg>`: Sugar for `load reg sp`, `add sp 8`.
- `jump <by:byte>`: Adds `by` to `ip`. Jumps are relative to the start of this instruction.
- `cjump <by:byte>`: Adds `by` to `ip` if `st` is not `0`. Jumps are relative to the start of this instruction.
- `call <target:word>`: Sugar for `push ip`, `movei target ip`.
- `ret`: Sugar for `load ip sp`, `addi sp 8` as if executed as a single instruction.
- `devicecall <device:byte>`: Makes the device handle the devicecall. It can access all the memory and registers.
- `cmp <left:reg> <right:reg>`: Saves `left` - `right` in `st`.
- `iszero`: If `st` is `0`, sets `st` to `1`, otherwise to `0`.
- `isless`: If `st` is less than `0`, sets `st` to `1`, otherwise to `0`.
- `isgreater`: If `st` is greater than `0`, sets `st` to `1`, otherwise to `0`.
- `islessequal`: If `st` is less than or equal `0`, sets `st` to `1`, otherwise to `0`.
- `isgreaterequal`: If `st` is greater than or equal `0`, sets `st` to `1`, otherwise to `0`.
- `add <to:reg> <from:reg>`: Adds `from` to `to`.
- `sub <to:reg> <from:reg>`: Subtracts `from` from `to`.
- `mul <to:reg> <from:reg>`: Multiplies `to` and `from`. Saves the result in `to`.
- `div <dividend:reg> <divisor:reg>`: Divides `dividend` by `divisor`. Saves the floored result in `dividend`, the remainder in `divisor`.
- `and <to:reg> <from:reg>`: Binary-ands `to` and `from`. Saves the result in `to`.
- `or <to:reg> <from:reg>`: Binary-ors `to` and `from`. Saves the result in `to`.
- `xor <to:reg> <from:reg>`: Binary-xors `to` and `from`. Saves the result in `to`.

## Recipes

Recipes are a textual representation of Soil machine code.
Recipe files end with `.recipe` and can be compiled into Soil binaries.

The anatomy of a recipe file:

- magic bytes `soil` (4 bytes)
- the only thing following are sections
  - type (1 byte)
  - length (8 byte), useful for skipping sections
  - content (length parsed above)
- name
  - section type `0`
  - length (8 bytes)
  - bytes
- description
  - section type `1`
  - length (8 bytes)
  - bytes
- devices
  - section type `2`
  - length (8 bytes)
  - number of devices (1 byte)
  - for each device (sockets assigned sequentially)
    - length of the hint (1 byte)
    - hint (length parsed above)
- machine code
  - section type `3`
  - length (8 bytes)
  - machine code (length parsed above)
