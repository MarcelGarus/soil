use std::{
    cmp::min,
    fs,
    io::Read,
    mem,
    process::exit,
};

use extension_trait::extension_trait;

const MEMORY_SIZE: usize = 500000;
const TRACE_CALLS: bool = true;

#[derive(Debug, Default)]
struct Vm {
    // Registers
    regs: [i64; 8], // sp, st, a, b, c, d, e, f

    // Memory
    memory: Vec<u8>,

    // Byte code
    byte_code: Vec<u8>,
    ip: usize,
    call_stack: Vec<usize>,

    // Debug stuff
    labels: Vec<(usize, String)>,
}
const SP: usize = 0;
const ST: usize = 1;
const REGA: usize = 2;
const REGB: usize = 3;
const REGC: usize = 4;
const REGD: usize = 5;
const REGE: usize = 6;
const REGF: usize = 7;

#[extension_trait]
impl WordFromByteSlice for [u8] {
    fn word_at(&self, pos: usize) -> i64 {
        if pos >= self.len() + 8 {
            panic!("out of bounds");
        }
        let pointer: &i64 = unsafe { mem::transmute(&self[pos]) };
        *pointer
    }
    fn word_at_mut(&mut self, pos: usize) -> &mut i64 {
        if pos >= self.len() + 8 {
            panic!("out of bounds");
        }
        unsafe { mem::transmute(&mut self[pos]) }
    }
}

struct Parser<'a> {
    input: &'a [u8],
}
impl<'a> Parser<'a> {
    fn done(&self) -> bool {
        self.input.is_empty()
    }
    fn advance_by(&mut self, n: usize) {
        self.input = &self.input[n..];
    }
    fn eat_byte(&mut self) -> u8 {
        if self.done() {
            panic!("binary incomplete");
        }
        let byte = self.input[0];
        self.advance_by(1);
        byte
    }
    fn eat_usize(&mut self) -> usize {
        if self.input.len() < 8 {
            panic!("binary incomplete");
        }
        let word = self.input.word_at(0);
        self.advance_by(8);
        word as usize
    }
}
impl Vm {
    fn init(binary: &[u8], args: &[String]) -> Self {
        let mut vm = Self::default();
        vm.regs[0] = MEMORY_SIZE as i64;

        vm.memory.reserve(MEMORY_SIZE);
        for _ in 0..MEMORY_SIZE {
            vm.memory.push(0);
        }

        // Push main function arguments to the stack.
        vm.regs[SP] -= (16 * args.len()) as i64;
        let slice = vm.regs[SP];
        for (i, arg) in args.iter().enumerate() {
            vm.regs[SP] -= arg.len() as i64;
            for (j, c) in arg.bytes().enumerate() {
                vm.memory[SP + j] = c;
            }
            *vm.memory.word_at_mut(slice as usize + 16 * i) = vm.regs[SP];
            *vm.memory.word_at_mut(slice as usize + 16 * i + 8) = arg.len() as i64;
        }
        vm.regs[SP] = vm.regs[SP] / 8 * 8;
        vm.regs[SP] -= 16;
        *vm.memory.word_at_mut(SP) = slice;
        *vm.memory.word_at_mut(SP + 8) = args.len() as i64;

        let mut parser = Parser { input: binary };
        assert_eq!(parser.eat_byte(), 's' as u8, "magic bytes don't match");
        assert_eq!(parser.eat_byte(), 'o' as u8, "magic bytes don't match");
        assert_eq!(parser.eat_byte(), 'i' as u8, "magic bytes don't match");
        assert_eq!(parser.eat_byte(), 'l' as u8, "magic bytes don't match");

        while !parser.done() {
            let section_type = parser.eat_byte();
            let section_len = parser.eat_usize();
            match section_type {
                0 => {
                    // machine code
                    assert!(section_len <= MEMORY_SIZE, "machine code too big");
                    for _ in 0..section_len {
                        vm.byte_code.push(parser.eat_byte());
                    }
                }
                3 => {
                    // debug info
                    let num_labels = parser.eat_usize();
                    for _ in 0..num_labels {
                        let pos = parser.eat_usize();
                        let len = parser.eat_usize();
                        let mut label = String::new();
                        for _ in 0..len {
                            label.push(parser.eat_byte() as char);
                        }
                        vm.labels.push((pos, label));
                    }
                }
                _ => {
                    parser.advance_by(section_len);
                }
            }
        }

        // printf("Memory:");
        // for (int i = 0; i < MEMORY_SIZE; i++) printf(" %02x", mem[i]);
        // printf("\n");

        vm
    }
}

impl Vm {
    fn find_label(&self, pos: usize) -> Option<(usize, &str)> {
        for (label_pos, label) in self.labels.iter().rev() {
            if *label_pos <= pos {
                return Some((pos, label));
            }
        }
        None
    }

    fn print_stack_entry(&self, pos: usize) {
        println!(
            "{:8x} {}",
            pos,
            self.find_label(pos).map_or("(no label)", |it| it.1)
        );
    }

    fn dump_and_panic(&self, msg: &str) {
        println!("{msg}");
        println!("Stack:");
        for entry in &self.call_stack {
            self.print_stack_entry(*entry);
        }
        self.print_stack_entry(self.ip);
        println!("");
        println!("Registers:");
        println!("ip = {:8} {:8x}", self.regs[SP], self.regs[SP]);
        println!("st = {:8} {:8x}", self.regs[ST], self.regs[ST]);
        println!("a  = {:8} {:8x}", self.regs[REGA], self.regs[REGA]);
        println!("b  = {:8} {:8x}", self.regs[REGB], self.regs[REGB]);
        println!("c  = {:8} {:8x}", self.regs[REGC], self.regs[REGC]);
        println!("d  = {:8} {:8x}", self.regs[REGD], self.regs[REGD]);
        println!("e  = {:8} {:8x}", self.regs[REGE], self.regs[REGE]);
        println!("f  = {:8} {:8x}", self.regs[REGF], self.regs[REGF]);
        println!("");
        fs::write("crash", &self.memory).unwrap();
        println!("Memory dumped to crash.");
        exit(1);
    }

    fn dump_reg(&self) {
        println!(
            "sp = {:x}, st = {:x}, a = {:x}, b = {:x}, c = {:x}, d = {:x}, e = {:x}, f = {:x}",
            self.regs[0],
            self.regs[1],
            self.regs[2],
            self.regs[3],
            self.regs[4],
            self.regs[5],
            self.regs[6],
            self.regs[7]
        );
    }

    fn eat_byte(&mut self) -> u8 {
        let byte = self.byte_code[self.ip];
        self.ip += 1;
        byte
    }
    fn eat_word(&mut self) -> i64 {
        let word = self.byte_code.word_at(self.ip);
        self.ip += 8;
        word
    }
    fn eat_reg(&mut self) -> usize {
        let byte = self.eat_byte();
        (byte & 0x0f) as usize
    }
    fn eat_regs(&mut self) -> (usize, usize) {
        let byte = self.eat_byte();
        ((byte & 0x0f) as usize, (byte >> 4 & 0x0f) as usize)
    }

    fn run_single(&mut self) {
        let opcode: u8 = self.eat_byte();
        // println!("ip {:x} has opcode {:x}\n", self.ip, opcode);
        match opcode {
            0x00 => {}                               // nop
            0xe0 => self.dump_and_panic("panicked"), // panic
            0xd0 => {
                // move
                let (a, b) = self.eat_regs();
                self.regs[a] = self.regs[b];
            }
            0xd1 => {
                // movei
                let reg = self.eat_reg();
                let value = self.eat_word();
                self.regs[reg] = value;
            }
            0xd2 => {
                // moveib
                let reg = self.eat_reg();
                let value = self.eat_byte();
                self.regs[reg] = value as i64;
            }
            0xd3 => {
                // load
                let (a, b) = self.eat_regs();
                if b > MEMORY_SIZE - 8 {
                    self.dump_and_panic("segmentation fault");
                }
                self.regs[a] = self.memory.word_at(self.regs[b] as usize);
            }
            0xd4 => {
                // loadb
                let (a, b) = self.eat_regs();
                if b > MEMORY_SIZE - 1 {
                    self.dump_and_panic("segmentation fault");
                }
                self.regs[a] = self.memory[self.regs[b] as usize] as i64;
            }
            0xd5 => {
                // store
                let (a, b) = self.eat_regs();
                if a > MEMORY_SIZE - 8 {
                    self.dump_and_panic("segmentation fault");
                }
                *self.memory.word_at_mut(self.regs[a] as usize) = self.regs[b];
            }
            0xd6 => {
                // storeb
                let (a, b) = self.eat_regs();
                if a > MEMORY_SIZE - 1 {
                    self.dump_and_panic("segmentation fault");
                }
                self.memory[self.regs[a] as usize] = self.regs[b] as u8;
            }
            0xd7 => {
                // push
                let reg = self.eat_reg();
                self.regs[SP] -= 8;
                *self.memory.word_at_mut(self.regs[SP] as usize) = self.regs[reg];
            }
            0xd8 => {
                // pop
                let reg = self.eat_reg();
                self.regs[reg] = self.memory.word_at(self.regs[SP] as usize);
                self.regs[SP] += 8;
            }
            0xf0 => self.ip = self.eat_word() as usize, // jump
            0xf1 => {
                // cjump
                let target = self.eat_word() as usize;
                if self.regs[ST] != 0 {
                    // println!("jumping because it's {}", self.regs[ST]);
                    self.ip = target;
                }
            }
            0xf2 => {
                // call
                let target = self.eat_word() as usize;
                if TRACE_CALLS {
                    for _ in 0..self.call_stack.len() {
                        print!(" ");
                    }
                    let label = self.find_label(target).map_or("(no label)", |it| it.1);
                    print!("{}", label);
                    for _ in (self.call_stack.len() + label.len())..50 {
                        print!(" ");
                    }
                    for i in (self.regs[SP] as usize)..min(MEMORY_SIZE, self.regs[SP] as usize + 40)
                    {
                        if i % 8 == 0 {
                            print!(" |");
                        }
                        print!(" {:02x}", self.memory[i]);
                    }
                    println!();
                }
                self.call_stack.push(self.ip);
                self.ip = target;
            }
            0xf3 => {
                // ret
                let target = self.call_stack.pop().unwrap();
                self.ip = target;
            }
            0xf4 => {
                // syscall
                let number = self.eat_byte();
                self.syscall(number);
            }
            0xc0 => {
                // cmp
                let (a, b) = self.eat_regs();
                self.regs[ST] = self.regs[a] - self.regs[b];
            }
            0xc1 => self.regs[ST] = i64::from(self.regs[ST] == 0), // isequal
            0xc2 => self.regs[ST] = i64::from(self.regs[ST] < 0),  // isless
            0xc3 => self.regs[ST] = i64::from(self.regs[ST] > 0),  // isgreater
            0xc4 => self.regs[ST] = i64::from(self.regs[ST] <= 0), // islessequal
            0xc5 => self.regs[ST] = i64::from(self.regs[ST] >= 0), // isgreaterequal
            0xa0 => {
                // add
                let (a, b) = self.eat_regs();
                self.regs[a] += self.regs[b];
            }
            0xa1 => {
                // sub
                let (a, b) = self.eat_regs();
                self.regs[a] -= self.regs[b];
            }
            0xa2 => {
                // mul
                let (a, b) = self.eat_regs();
                self.regs[a] *= self.regs[b];
            }
            0xa3 => {
                // div
                let (a, b) = self.eat_regs();
                self.regs[a] /= self.regs[b];
            }
            0xa4 => {
                // rem
                let (a, b) = self.eat_regs();
                self.regs[a] %= self.regs[b];
            }
            0xb0 => {
                // and
                let (a, b) = self.eat_regs();
                self.regs[a] &= self.regs[b];
            }
            0xb1 => {
                // or
                let (a, b) = self.eat_regs();
                self.regs[a] |= self.regs[b];
            }
            0xb2 => {
                // xor
                let (a, b) = self.eat_regs();
                self.regs[a] ^= self.regs[b];
            }
            0xb3 => {
                // xor
                let reg = self.eat_reg();
                self.regs[reg] = !self.regs[reg];
            }
            _ => self.dump_and_panic("invalid instruction"),
        }
    }

    fn run(&mut self) {
        loop {
            // self.dump_reg();
            // printf("Memory:");
            // for (int i = 0x18650; i < MEMORY_SIZE; i++)
            //   printf("%c%02x", i == SP ? '|' : ' ', mem[i]);
            // printf("\n");
            self.run_single();
        }
    }

    fn syscall(&mut self, number: u8) {
        match number {
            0 => self.syscall_exit(),
            1 => self.syscall_print(),
            2 => self.syscall_log(),
            3 => self.syscall_create(),
            4 => self.syscall_open_reading(),
            5 => self.syscall_open_writing(),
            6 => self.syscall_read(),
            7 => self.syscall_write(),
            8 => self.syscall_close(),
            _ => self.dump_and_panic("invalid syscall number"),
        }
    }

    fn syscall_exit(&self) {
        println!("exiting with status {}", self.regs[REGA]);
        exit(self.regs[REGA] as i32);
    }

    fn syscall_print(&self) {
        for i in 0..self.regs[REGB] {
            print!("{}", self.memory[(self.regs[REGA] + i) as usize] as char);
        }
    }

    fn syscall_log(&self) {
        for i in 0..self.regs[REGB] {
            eprint!("{}", self.memory[(self.regs[REGA] + i) as usize] as char);
        }
    }

    fn syscall_create(&self) {
        todo!("create file")
        // let filename = str::from_raw_parts(self.memory[self.regs[2] as usize], self.regs[3], self.regs[3]);
        // let file = File::create(filename);
    }

    fn syscall_open_reading(&self) {
        todo!()
        // char filename[REGB];
        // for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
        // filename[REGB] = 0;
        // printf("opening filename %s\n", filename);
        // REGA = (Word)fopen(filename, "r");
    }

    fn syscall_open_writing(&self) {
        todo!()
        // char filename[REGB];
        // for (int i = 0; i < REGB; i++) filename[i] = mem[REGA + i];
        // filename[REGB] = 0;
        // REGA = (Word)fopen(filename, "w+");
    }

    fn syscall_read(&self) {
        todo!()
        // REGA = fread(mem + REGB, 1, REGC, (FILE*)REGA);
    }

    fn syscall_write(&self) {
        // TODO: assert that this worked
        todo!()
        // fwrite(mem + REGB, 1, REGC, (FILE*)REGA);
    }

    fn syscall_close(&self) {
        // TODO: assert that this worked
        todo!()
        // fclose((FILE*)REGA);
    }
}

fn main() {
    let mut binary = Vec::new();
    std::io::stdin().lock().read_to_end(&mut binary).unwrap();

    let args: Vec<_> = std::env::args().collect();

    let mut vm = Vm::init(&binary, &args);
    vm.run();
}
