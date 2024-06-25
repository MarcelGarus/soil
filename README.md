# Soil

Soil is a virtual machine specification that is designed to be easy to implement on typical machines.

![Soil](Soil.png)

To get started, run `make`.
This creates some executables:

- `assemble`: can turn `.recipe` files (Soil assembly) into `.soil` files (Soil binaries).
- `soil-c`: Reference implementation of a Soil interpreter written in C. This is slow.
- `soil-asm`: A Soil JIT compiler written in Assembly. Some syscalls are missing and there are some bugs.
- `soil-rust-compiler`: A Soil compiler to FASM written in Rust.

For example, to run the `hello.recipe`, you can run this:

```sh
cat hello.recipe | ./assemble | ./soil-c
```

## The Anatomy of Soil

Soil consists of three parts of state: registers, memory, and byte code.

Soil is not a von Neumann machine – byte code and memory live in separate worlds.
Byte code can only read/write the memory, not byte code itself.
You can't reflect on the byte code itself, for example, to store pointers to instructions.
This gives Soil implementations the freedom to JIT-compile the byte code on startup.

Soil binaries are files that contain byte code and initial memory.

### Registers

Soil has 8 registers, all of which hold 64 bits.

| name | description              |
| ---- | ------------------------ |
| `sp` | stack pointer            |
| `st` | status register          |
| `a`  | general-purpose register |
| `b`  | general-purpose register |
| `c`  | general-purpose register |
| `d`  | general-purpose register |
| `e`  | general-purpose register |
| `f`  | general-purpose register |

Initially, `sp` is the memory size.
All other registers are zero.

### Memory

It also has byte-addressed memory.
For now, the size of the memory is hardcoded to something big.

### Byte Code

Byte code consists of a sequence of instructions.

Soil runs the instructions in sequence, starting from the first.
Some instructions alter control flow by jumping to other instructions.

All instructions start with a byte containing the opcode, followed by the arguments to the operation.
The following instructions are available:

| opcode | mnemonic        | arg 0         | arg 1        | description                                                                                           |
| ------ | --------------- | ------------- | ------------ | ----------------------------------------------------------------------------------------------------- |
| 00     | nop             | -             | -            | Does nothing.                                                                                         |
| e0     | panic           | -             | -            | Panics.                                                                                               |
| d0     | move            | to: reg       | from: reg    | Sets `to` to `from`.                                                                                  |
| d1     | movei           | to: reg       | value: word  | Sets `to` to `value`.                                                                                 |
| d2     | moveib          | to: reg       | value: byte  | Sets `to` to `value`, zeroing the upper bits.                                                         |
| d3     | load            | to: reg       | from: reg    | Interprets `from` as an address and sets `to` to the 64 bits at that address in memory.               |
| d4     | loadb           | to: reg       | from: reg    | Interprets `from` as an address and sets `to` to the 8 bits at that address in memory.                |
| d5     | store           | to: reg       | from: reg    | Interprets `to` as an address and sets the 64 bits at that address in memory to `from`.               |
| d6     | storeb          | to: reg       | from: reg    | Interprets `to` as an address and sets the 8 bits at that address in memory to `from`.                |
| d7     | push            | reg: reg      | -            | Decreases `sp` by 8, then runs `store sp reg`.                                                        |
| d8     | pop             | reg: reg      | -            | Runs `load reg sp`, then increases `sp` by 8.                                                         |
| f0     | jump            | to: word      | -            | Continues executing at the `to`th byte.                                                               |
| f1     | cjump           | to: word      | -            | Runs `jump to` if `st` is not 0.                                                                      |
| f2     | call            | target: word  | -            | Runs `jump target`. Saves the formerly next instruction on an internal stack so that `ret` returns.   |
| f3     | ret             | -             | -            | Returns to the instruction after the matching `call`.                                                 |
| f4     | syscall         | number: byte  | -            | Performs a syscall. Behavior depends on the syscall. The syscall can access all registers and memory. |
| c0     | cmp             | left: reg     | right: reg   | Saves `left` - `right` in `st`.                                                                       |
| c1     | isequal         | -             | -            | If `st` is 0, sets `st` to 1, otherwise to 0.                                                         |
| c2     | isless          | -             | -            | If `st` is less than 0, sets `st` to 1, otherwise to 0.                                               |
| c3     | isgreater       | -             | -            | If `st` is greater than 0, sets `st` to 1, otherwise to 0.                                            |
| c4     | islessequal     | -             | -            | If `st` is 0 or less, sets `st` to 1, otherwise to 0.                                                 |
| c5     | isgreaterequal  | -             | -            | If `st` is 0 or greater, sets `st` to 1, otherwise to 0.                                              |
| c6     | isnotequal      | -             | -            | If `st` is 0, sets `st` to 0, otherwise to 1.                                                         |
| c7     | fisequal        | -             | -            | If `st` is 0, sets `st` to 1, otherwise to 0.                                                         |
| c8     | fisless         | -             | -            | If `st` is less than 0, sets `st` to 1, otherwise to 0.                                               |
| c9     | fisgreater      | -             | -            | If `st` is greater than 0, sets `st` to 1, otherwise to 0.                                            |
| ca     | fislessequal    | -             | -            | If `st` is 0 or less, sets `st` to 1, otherwise to 0.                                                 |
| cb     | fisgreaterequal | -             | -            | If `st` is 0 or greater, sets `st` to 1, otherwise to 0.                                              |
| cc     | fisnotequal     | -             | -            | If `st` is 0, sets `st` to 0, otherwise to 1.                                                         |
| cd     | inttofloat      | reg: reg      | -            | Interprets `reg` as an int and sets it to a float of about the same value. TODO: specify edge cases   |
| ce     | floattoint      | reg: reg      | -            | Interprets `reg` as a float and sets it to its int, rounded down. TODO: specify edge cases            |
| a0     | add             | to: reg       | from: reg    | Adds `from` to `to`.                                                                                  |
| a1     | sub             | to: reg       | from: reg    | Subtracts `from` from `to`.                                                                           |
| a2     | mul             | to: reg       | from: reg    | Multiplies `from` and `to`. Saves the result in `to`.                                                 |
| a3     | div             | dividend: reg | divisor: reg | Divides `dividend` by `divisor`. Saves the quotient in `dividend`.                                    |
| a4     | rem             | dividend: reg | divisor: reg | Divides `dividend` by `divisor`. Saves the remainder in `dividend`.                                   |
| a5     | fadd            | to: reg       | from: reg    | Adds `from` to `to`, interpreted as floats.                                                           |
| a6     | fsub            | to: reg       | from: reg    | Subtracts `from` from `to`, interpreted as floats.                                                    |
| a7     | fmul            | to: reg       | from: reg    | Multiplies `from` and `to`, interpreted as floats. Saves the result in `to`.                          |
| a8     | fdiv            | dividend: reg | divisor: reg | Divides `dividend` by `divisor`, interpreted as floats. Saves the quotient in `dividend`.             |
| b0     | and             | to: reg       | from: reg    | Binary-ands `to` and `from`. Saves the result in `to`.                                                |
| b1     | or              | to: reg       | from: reg    | Binary-ors `to` and `from`. Saves the result in `to`.                                                 |
| b2     | xor             | to: reg       | from: reg    | Binary-xors `to` and `from`. Saves the result in `to`.                                                |
| b3     | not             | to: reg       | -            | Inverts the bits of `to`.                                                                             |

To make memorization easier, the first characters of the instruction hex opcodes describe what kind of instruction it is:

- 00: nop
- a*: arithmetic
- b*: binary
- c*: comparisons / conversions
- d*: data operations
- e*: error
- f*: control flow

## Binaries

Soil binaries are stuctured like this:

- magic bytes `soil` (4 bytes)
- the only thing following are sections, each of which has:
  - type (1 byte)
  - length (8 byte), useful for skipping sections
  - content (length parsed above)
- byte code
  - section type `0`
  - length (8 bytes)
  - byte code (length parsed above)
- initial memory
  - section type `1`
  - length (8 bytes)
  - content (length parsed above)
- name
  - section type `2`
  - length (8 bytes)
  - content (length parsed above)
- labels
  - section type `3`
  - length (8 bytes)
  - number of labels (8 bytes)
  - for each label:
    - position in the byte code (8 bytes)
    - label length (8 bytes)
    - label (length parsed above)
- description
  - section type `4`
  - length (8 bytes)
  - content (length parsed above)
