mod binary;
mod utils;
mod interpreter;
mod jit;

use std::io::Read;
use binary::Binary;
use cranelift::codegen::isa::TargetIsa;
use interpreter::Vm;
use jit::compile;

fn main() {
    let mut bytes = vec![];
    std::io::stdin().lock().read_to_end(&mut bytes).unwrap();

    let binary = Binary::parse(&bytes);

    let args: Vec<_> = std::env::args().collect();

    compile(binary);

    // let mut vm = Vm::init(binary);
    // vm.run();
}
