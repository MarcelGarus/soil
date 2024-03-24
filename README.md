# Soil

Soil is a bytecode interpreter.
It can run Soil binaries, which are files that end with `.soil`.

Soil is designed to be easy to implement on typical machines.
It has 8 registers and memory.

![Soil](Soil.png)

## Binaries

Soil binaries contain the machine code.
They can also contain a description of the program and debug information.

Upon startup, Soil does the following:

1. Load the machine code into memory at address 0
2. Set initial register contents
   1. the instruction pointer `ip` to 0, the address of the machine code
   2. the stack pointer `sp` to the last memory address
   3. all other registers to zero
3. Run the code
   1. Parse the instruction that `ip` points to
   2. Run it
   3. Repeat

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

| opcode | mnemonic       | arg 0         | arg 1        | description                                                                                           |
| ------ | -------------- | ------------- | ------------ | ----------------------------------------------------------------------------------------------------- |
| 00     | nop            | -             | -            | Does nothing.                                                                                         |
| e0     | panic          | -             | -            | Panics with a message. Interprets `a` as a pointer to a message and `b` as the length of the message. |
| d0     | move           | to: reg       | from: reg    | Sets `to` to `from`.                                                                                  |
| d1     | movei          | to: reg       | value: word  | Sets `to` to `value`.                                                                                 |
| d2     | moveib         | to: reg       | value: byte  | Sets `to` to `value`, zeroing the upper bits.                                                         |
| d3     | load           | to: reg       | from: reg    | Interprets `from` as an address and sets `to` to the 64 bits at that address in memory.               |
| d4     | loadb          | to: reg       | from: reg    | Interprets `from` as an address and sets `to` to the 8 bits at that address in memory.                |
| d5     | store          | to: reg       | from: reg    | Interprets `to` as an address and sets the 64 bits at that address in memory to `from`.               |
| d6     | storeb         | to: reg       | from: reg    | Interprets `to` as an address and sets the 8 bits at that address in memory to `from`.                |
| d7     | push           | reg: reg      | -            | Decreases `sp` by 8, then runs `store sp reg`.                                                        |
| d8     | pop            | reg: reg      | -            | Runs `load reg sp`, then increases `sp` by 8.                                                         |
| f0     | jump           | to: word      | -            | Runs `loadi ip to`.                                                                                   |
| f1     | cjump          | to: word      | -            | Runs `jump to` if `st` is not 0.                                                                      |
| f2     | call           | target: word  | -            | Runs `push ip`, `jump target`.                                                                        |
| f3     | ret            | -             | -            | Runs `load ip`, then increases `sp` by 8.                                                             |
| f4     | syscall        | number: byte  | -            | Performs a syscall. Behavior depends on the syscall. The syscall can access all registers and memory. |
| c0     | cmp            | left: reg     | right: reg   | Saves `left` - `right` in `st`.                                                                       |
| c1     | isequal        | -             | -            | If `st` is 0, sets `st` to 1, otherwise to 0.                                                         |
| c2     | isless         | -             | -            | If `st` is less than 0, sets `st` to 1, otherwise to 0.                                               |
| c3     | isgreater      | -             | -            | If `st` is greater than 0, sets `st` to 1, otherwise to 0.                                            |
| c4     | islessequal    | -             | -            | If `st` is 0 or less, sets `st` to 1, otherwise to 0.                                                 |
| c5     | isgreaterequal | -             | -            | If `st` is 0 or greater, sets `st` to 1, otherwise to 0.                                              |
| a0     | add            | to: reg       | from: reg    | Adds `from` to `to`.                                                                                  |
| a1     | sub            | to: reg       | from: reg    | Subtracts `from` from `to`.                                                                           |
| a2     | mul            | to: reg       | from: reg    | Multiplies `from` and `to`. Saves the result in `to`.                                                 |
| a3     | div            | dividend: reg | divisor: reg | Divides `dividend` by `divisor`. Saves the floored result in `dividend`, the remainder in `divisor`.  |
| b0     | and            | to: reg       | from: reg    | Binary-ands `to` and `from`. Saves the result in `to`.                                                |
| b1     | or             | to: reg       | from: reg    | Binary-ors `to` and `from`. Saves the result in `to`.                                                 |
| b2     | xor            | to: reg       | from: reg    | Binary-xors `to` and `from`. Saves the result in `to`.                                                |
| b3     | negate         | to: reg       | -            | Negates `to`.                                                                                         |

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
- machine code
  - section type `3`
  - length (8 bytes)
  - machine code (length parsed above)
