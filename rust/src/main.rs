mod binary;
mod utils;
// mod interpreter;
mod compile;

use std::io::Read;
use binary::Binary;
// use interpreter::Vm;

fn main() {
    let mut bytes = vec![];
    std::io::stdin().lock().read_to_end(&mut bytes).unwrap();

    let binary = Binary::parse(&bytes);

    // let args: Vec<_> = std::env::args().collect();

    let asm = compile::compile(binary);
    println!("{}", asm);

    // let mut vm = Vm::init(binary);
    // vm.run();
}
