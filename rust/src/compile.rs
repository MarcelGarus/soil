use extension_trait::extension_trait;

use crate::{binary::Binary, utils::WordFromByteSlice};

const MEMORY_SIZE: usize = 1000;

// Compiles the program into a function with the following signature:
//
// ```
// program(u8* memory, i64 memory_len, i64* call_stack) -> u8
// ```
//
// The return value indicates what the program did:
// 0: exit
// 1: panicked
pub fn compile(binary: Binary) -> String {
    let mut out = String::new();

    out.push_str("; fasm\n");
    out.push_str("format ELF64 executable\n");
    out.push_str("segment readable executable\n");

    for reg in REGS {
        out.push_str(&format!("{:7}mov {}, {}\n", "", reg.to_asm(), match reg {
            Reg::SP => MEMORY_SIZE,
            _ => 0,
        }));
    }

    let mut byte_code = binary.byte_code.byte_code();
    loop {
        let cursor = byte_code.cursor;
        let instruction = match byte_code.next() {
            Some(instruction) => instruction,
            None => break,
        };

        out.push_str(&format!("{:7}", format!("i{}: ", cursor)));
        match instruction {
            Instruction::Nop => {}
            Instruction::Panic => out.push_str("call panic\n"),
            Instruction::Move_(a, b) => {
                out.push_str(&format!("mov {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Movei(a, value) => {
                out.push_str(&format!("mov {}, {}\n", a.to_asm(), value))
            }
            Instruction::Moveib(a, value) => {
                out.push_str(&format!("mov {}, {}\n", a.to_asm(), value))
            }
            Instruction::Load(a, b) => {
                out.push_str(&format!("mov {}, [memory + {}]\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Loadb(a, b) => {
                out.push_str(&format!("mov {}b, [memory + {}]\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Store(a, b) => {
                out.push_str(&format!("mov [memory + {}], {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Storeb(a, b) => {
                out.push_str(&format!("mov [memory + {}], {}b\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Push(a) => out.push_str(&format!("push {}\n", a.to_asm())),
            Instruction::Pop(a) => out.push_str(&format!("pop {}\n", a.to_asm())),
            Instruction::Jump(target) => out.push_str(&format!("jmp i{}\n", target)),
            Instruction::Cjump(target) => {
                out.push_str(&format!("cmp r9, 0\n"));
                out.push_str(&format!("{:7}jnz i{}\n", "", target))
            }
            Instruction::Call(target) => out.push_str(&format!("call i{}\n", target)),
            Instruction::Ret => out.push_str("ret\n"),
            Instruction::Syscall(number) => out.push_str(&format!("call syscall_{}\n", number)),
            Instruction::Cmp(a, b) => {
                out.push_str(&format!("mov r9, {}\n", a.to_asm()));
                out.push_str(&format!("{:7}sub r9, {}\n", "", b.to_asm()))
            }
            Instruction::Isequal => {
                out.push_str("mov rax, 0\n");
                out.push_str(&format!("{:7}mov rbx, 1\n", ""));
                out.push_str(&format!("{:7}cmove r9, rbx\n", ""));
                out.push_str(&format!("{:7}cmovne r9, rax\n", ""))
            }
            Instruction::Isless => {
                out.push_str("mov rax, 0\n");
                out.push_str(&format!("{:7}mov rbx, 1\n", ""));
                out.push_str(&format!("{:7}cmovb r9, rbx\n", ""));
                out.push_str(&format!("{:7}cmovnb r9, rax\n", ""))
            }
            Instruction::Isgreater => {
                out.push_str("mov rax, 0\n");
                out.push_str(&format!("{:7}mov rbx, 1\n", ""));
                out.push_str(&format!("{:7}cmova r9, rbx\n", ""));
                out.push_str(&format!("{:7}cmovna r9, rax\n", ""))
            }
            Instruction::Islessequal => {
                out.push_str("mov rax, 0\n");
                out.push_str(&format!("{:7}mov rbx, 1\n", ""));
                out.push_str(&format!("{:7}cmovbe r9, rbx\n", ""));
                out.push_str(&format!("{:7}cmovnbe r9, rax\n", ""))
            }
            Instruction::Isgreaterequal => {
                out.push_str("mov rax, 0\n");
                out.push_str(&format!("{:7}mov rbx, 1\n", ""));
                out.push_str(&format!("{:7}cmovae r9, rbx\n", ""));
                out.push_str(&format!("{:7}cmovnae r9, rax\n", ""))
            }
            Instruction::Add(a, b) => {
                out.push_str(&format!("add {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Sub(a, b) => {
                out.push_str(&format!("sub {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Mul(a, b) => {
                out.push_str(&format!("mul {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Div(a, b) => {
                out.push_str(&format!("div {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Rem(a, b) => {
                out.push_str(&format!("div {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::And(a, b) => {
                out.push_str(&format!("and {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Or(a, b) => out.push_str(&format!("or {}, {}\n", a.to_asm(), b.to_asm())),
            Instruction::Xor(a, b) => {
                out.push_str(&format!("xor {}, {}\n", a.to_asm(), b.to_asm()))
            }
            Instruction::Negate(a) => out.push_str(&format!("neg {}\n", a.to_asm())),
        }
    }

    out.push_str(&format!("{:7}", "panic:"));
    out.push_str(&format!("mov rax, 60\n"));
    out.push_str(&format!("{:7}mov rdi, 1\n", ""));
    out.push_str(&format!("{:7}syscall\n", ""));
    out.push_str(&format!("{:7}ret\n", ""));

    fn save_registers(out: &mut String) {
        for reg in REGS {
            out.push_str(&format!("{:7}push {}\n", "", reg.to_asm()));
        }
    }
    fn restore_registers(out: &mut String) {
        for reg in REGS
        .iter()
        .rev()
        {
            out.push_str(&format!("{:7}pop {}\n", "", reg.to_asm()));
        }
    }

    out.push_str("syscall_0: ; exit\n");
    out.push_str(&format!("{:7}mov rax, 60\n", ""));
    out.push_str(&format!("{:7}mov rdi, 0\n", ""));
    out.push_str(&format!("{:7}syscall\n", ""));

    out.push_str("syscall_1: ; print\n");
    save_registers(&mut out);
    out.push_str(&format!("{:7}mov rax, 1\n", ""));
    out.push_str(&format!("{:7}mov rdi, 1\n", ""));
    out.push_str(&format!("{:7}mov rsi, r10\n", ""));
    out.push_str(&format!("{:7}add rsi, memory\n", ""));
    out.push_str(&format!("{:7}mov rdx, r11\n", ""));
    out.push_str(&format!("{:7}syscall\n", ""));
    restore_registers(&mut out);
    out.push_str(&format!("{:7}ret\n", ""));
    
    out.push_str("syscall_2: ; log\n");
    save_registers(&mut out);
    out.push_str(&format!("{:7}mov rax, 1\n", ""));
    out.push_str(&format!("{:7}mov rdi, 2\n", ""));
    out.push_str(&format!("{:7}mov rsi, r10\n", ""));
    out.push_str(&format!("{:7}add rsi, memory\n", ""));
    out.push_str(&format!("{:7}mov rdx, r11\n", ""));
    out.push_str(&format!("{:7}syscall\n", ""));
    restore_registers(&mut out);
    out.push_str(&format!("{:7}ret\n", ""));

    out.push_str("segment readable writable\n");
    out.push_str("call_stack:\n");
    out.push_str("  dq 1024 dup 8\n");
    out.push_str(".len:\n");
    out.push_str("  dq 0\n");
    out.push_str("memory:\n");
    if !binary.memory.is_empty() {
        out.push_str("  db");
        let mut is_first = true;
        for byte in &binary.memory {
            out.push_str(&format!("{} {}", if is_first { "" } else { "," }, byte));
            is_first = false;
        }
        out.push_str("\n");
    }
    out.push_str(&format!("  dq {} dup 0", 1000 - binary.memory.len()));

    return out;
}

impl Reg {
    fn to_asm(&self) -> &'static str {
        match self {
            Reg::SP => "r8",
            Reg::ST => "r9",
            Reg::A => "r10",
            Reg::B => "r11",
            Reg::C => "r12",
            Reg::D => "r13",
            Reg::E => "r14",
            Reg::F => "r15",
        }
    }
}

#[extension_trait]
impl ByteCode for [u8] {
    fn byte_code(&self) -> ByteCodeParser {
        ByteCodeParser {
            input: self,
            cursor: 0,
        }
    }
}

struct ByteCodeParser<'a> {
    input: &'a [u8],
    cursor: usize,
}
impl<'a> ByteCodeParser<'a> {
    fn done(&self) -> bool {
        self.cursor >= self.input.len()
    }
    fn advance_by(&mut self, n: usize) {
        self.cursor += n;
    }
    fn eat_byte(&mut self) -> Option<u8> {
        if self.done() {
            return None;
        }
        let byte = self.input[self.cursor];
        self.advance_by(1);
        Some(byte)
    }
    fn eat_i64(&mut self) -> Option<i64> {
        if self.input.len() - self.cursor < 8 {
            return None;
        }
        let word = self.input.word_at(self.cursor);
        self.advance_by(8);
        Some(word)
    }
    fn eat_usize(&mut self) -> Option<usize> {
        self.eat_i64().map(|word| word as usize)
    }
    fn eat_reg(&mut self) -> Reg {
        let byte = self.eat_byte().expect("expected register\n");
        Reg::try_from(byte & 0x0f).unwrap()
    }
    fn eat_regs(&mut self) -> (Reg, Reg) {
        let byte = self.eat_byte().expect("expected registers\n");
        (
            Reg::try_from(byte & 0x0f).unwrap(),
            Reg::try_from(byte >> 4 & 0x0f).unwrap(),
        )
    }
}

enum Instruction {
    Nop,
    Panic,
    Move_(Reg, Reg),
    Movei(Reg, i64),
    Moveib(Reg, u8),
    Load(Reg, Reg),
    Loadb(Reg, Reg),
    Store(Reg, Reg),
    Storeb(Reg, Reg),
    Push(Reg),
    Pop(Reg),
    Jump(usize),
    Cjump(usize),
    Call(usize),
    Ret,
    Syscall(u8),
    Cmp(Reg, Reg),
    Isequal,
    Isless,
    Isgreater,
    Islessequal,
    Isgreaterequal,
    Add(Reg, Reg),
    Sub(Reg, Reg),
    Mul(Reg, Reg),
    Div(Reg, Reg),
    Rem(Reg, Reg),
    And(Reg, Reg),
    Or(Reg, Reg),
    Xor(Reg, Reg),
    Negate(Reg),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Reg {
    SP,
    ST,
    A,
    B,
    C,
    D,
    E,
    F,
}
const REGS: [Reg; 8] = [Reg::SP, Reg::ST, Reg::A, Reg::B, Reg::C, Reg::D, Reg::E, Reg::F];

impl TryFrom<u8> for Reg {
    type Error = ();

    fn try_from(value: u8) -> Result<Self, ()> {
        Ok(match value {
            0 => Reg::SP,
            1 => Reg::ST,
            2 => Reg::A,
            3 => Reg::B,
            4 => Reg::C,
            5 => Reg::D,
            6 => Reg::E,
            7 => Reg::F,
            _ => return Err(()),
        })
    }
}

impl<'a> Iterator for ByteCodeParser<'a> {
    type Item = Instruction;

    fn next(&mut self) -> Option<Self::Item> {
        Some(match self.eat_byte()? {
            0x00 => Instruction::Nop,
            0xe0 => Instruction::Panic,
            0xd0 => {
                let (a, b) = self.eat_regs();
                Instruction::Move_(a, b)
            }
            0xd1 => {
                let reg = self.eat_reg();
                let value = self.eat_i64().unwrap();
                Instruction::Movei(reg, value)
            }
            0xd2 => {
                let reg = self.eat_reg();
                let value = self.eat_byte().unwrap();
                Instruction::Moveib(reg, value)
            }
            0xd3 => {
                let (a, b) = self.eat_regs();
                Instruction::Load(a, b)
            }
            0xd4 => {
                let (a, b) = self.eat_regs();
                Instruction::Loadb(a, b)
            }
            0xd5 => {
                let (a, b) = self.eat_regs();
                Instruction::Store(a, b)
            }
            0xd6 => {
                let (a, b) = self.eat_regs();
                Instruction::Storeb(a, b)
            }
            0xd7 => Instruction::Push(self.eat_reg()),
            0xd8 => Instruction::Pop(self.eat_reg()),
            0xf0 => Instruction::Jump(self.eat_usize().unwrap()),
            0xf1 => Instruction::Cjump(self.eat_usize().unwrap()),
            0xf2 => Instruction::Call(self.eat_usize().unwrap()),
            0xf3 => Instruction::Ret,
            0xf4 => Instruction::Syscall(self.eat_byte().unwrap()),
            0xc0 => {
                let (a, b) = self.eat_regs();
                Instruction::Cmp(a, b)
            }
            0xc1 => Instruction::Isequal,
            0xc2 => Instruction::Isless,
            0xc3 => Instruction::Isgreater,
            0xc4 => Instruction::Islessequal,
            0xc5 => Instruction::Isgreaterequal,
            0xa0 => {
                let (a, b) = self.eat_regs();
                Instruction::Add(a, b)
            }
            0xa1 => {
                let (a, b) = self.eat_regs();
                Instruction::Sub(a, b)
            }
            0xa2 => {
                let (a, b) = self.eat_regs();
                Instruction::Mul(a, b)
            }
            0xa3 => {
                let (a, b) = self.eat_regs();
                Instruction::Div(a, b)
            }
            0xa4 => {
                let (a, b) = self.eat_regs();
                Instruction::Rem(a, b)
            }
            0xb0 => {
                let (a, b) = self.eat_regs();
                Instruction::And(a, b)
            }
            0xb1 => {
                let (a, b) = self.eat_regs();
                Instruction::Or(a, b)
            }
            0xb2 => {
                let (a, b) = self.eat_regs();
                Instruction::Xor(a, b)
            }
            0xb3 => Instruction::Negate(self.eat_reg()),
            opcode => panic!("unknown opcode {}\n", opcode),
        })
    }
}
