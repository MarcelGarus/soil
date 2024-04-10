use std::{collections::HashMap, sync::Arc};

use cranelift::{
    codegen::{
        ir::{immediates::Offset32, types, Function, UserFuncName},
        isa::TargetIsa,
        Context,
    },
    prelude::*,
};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{DataDescription, FuncId, Init, Module};
use cranelift_object::{ObjectBuilder, ObjectModule};
use extension_trait::extension_trait;

use crate::{binary::Binary, utils::WordFromByteSlice};

pub fn compile(binary: Binary) {
    let mut flag_builder = settings::builder();
    flag_builder.set("use_colocated_libcalls", "false").unwrap();
    flag_builder.set("is_pic", "false").unwrap();
    let isa_builder = cranelift_native::builder().unwrap_or_else(|msg| {
        panic!("host machine is not supported: {}", msg);
    });
    let isa = isa_builder
            .finish(settings::Flags::new(flag_builder))
            .unwrap();
        let builder = JITBuilder::with_isa(isa, cranelift_module::default_libcall_names());
    
    let mut module = JITModule::new(builder);
    let ctx = module.make_context();
    let func_id = module
        .declare_function("run", cranelift_module::Linkage::Export, &ctx.func.signature)
        .unwrap();

    let fn_name = UserFuncName::user(0, 0);

    let mut fun = Function::with_name_signature(fn_name, ctx.func.signature.clone());

    // The program gets converted into a single function that takes a pointer to
    // the memory and the length as an argument.
    fun.signature.params.push(AbiParam::new(module.target_config().pointer_type()));
    fun.signature.params.push(AbiParam::new(types::I64));
    fun.signature.returns.push(AbiParam::new(types::I8));

    let mut fun_ctx = FunctionBuilderContext::new();
    let mut builder = FunctionBuilder::new(&mut fun, &mut fun_ctx);

    let entry = builder.create_block();
    builder.append_block_params_for_function_params(entry);
    builder.switch_to_block(entry);
    builder.seal_block(entry);

    let zero = builder.ins().iconst(types::I64, 0);
    let one = builder.ins().iconst(types::I64, 1);

    // The registers are held in variables.
    for reg in [Reg::SP, Reg::ST, Reg::A, Reg::B, Reg::C, Reg::D, Reg::E, Reg::F] {
        builder.declare_var(reg.into(), types::I64);
        builder.def_var(reg.into(), zero);
    }

    let memory = Variable::new(8);
    builder.declare_var(memory, module.target_config().pointer_type());
    builder.def_var(memory, builder.block_params(entry)[0]);

    for instruction in binary.byte_code.byte_code() {
        let instruction_block = builder.create_block();
        builder.switch_to_block(instruction_block);
        match instruction {
            Instruction::Nop => {},
            Instruction::Panic => {
                builder.ins().return_(&[one]);
            },
            Instruction::Move_(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                builder.ins().store(MemFlags::new(), b, a, Offset32::new(0));
            },
            Instruction::Movei(a, value) => {
                let to = builder.use_var(a.into());
                let value = builder.ins().iconst(types::I64, i64::from(value));
                builder.ins().store(MemFlags::new(), value, to, Offset32::new(0));
            },
            Instruction::Moveib(a, value) => {
                let to = builder.use_var(a.into());
                let value = builder.ins().iconst(types::I8, value as i64);
                builder.ins().store(MemFlags::new(), value, to, Offset32::new(0));
            }
            Instruction::Load(_, _) => todo!(),
            Instruction::Loadb(_, _) => todo!(),
            Instruction::Store(_, _) => todo!(),
            Instruction::Storeb(_, _) => todo!(),
            Instruction::Push(_) => todo!(),
            Instruction::Pop(_) => todo!(),
            Instruction::Jump(_) => todo!(),
            Instruction::Cjump(_) => todo!(),
            Instruction::Call(_) => todo!(),
            Instruction::Ret => todo!(),
            Instruction::Syscall(_) => todo!(),
            Instruction::Cmp(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().isub(a, b);
                let st = builder.use_var(Reg::ST.into());
                builder.ins().store(MemFlags::new(), res, st, Offset32::new(0));
            },
            Instruction::Isequal => todo!(),
            Instruction::Isless => todo!(),
            Instruction::Isgreater => todo!(),
            Instruction::Islessequal => todo!(),
            Instruction::Isgreaterequal => todo!(),
            Instruction::Add(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().iadd(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Sub(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().isub(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Mul(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().imul(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Div(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().sdiv(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Rem(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().srem(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::And(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().band(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Or(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().bor(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Xor(a, b) => {
                let a = builder.use_var(a.into());
                let b = builder.use_var(b.into());
                let res = builder.ins().bxor(a, b);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
            Instruction::Negate(a) => {
                let a = builder.use_var(a.into());
                let res = builder.ins().bnot(a);
                builder.ins().store(MemFlags::new(), res, a, Offset32::new(0));
            },
        }
    }

    builder.seal_all_blocks();
    //info!("{}", func_builder.func.display());
    builder.finalize();

    let mut ctx = Context::for_function(fun);

    ctx.compute_cfg();
    ctx.compute_domtree();
    ctx.verify(module.isa()).unwrap();
    // ctx.dce(module.isa()).unwrap();
    // ctx.eliminate_unreachable_code(module.isa()).unwrap();
    // ctx.replace_redundant_loads().unwrap();
    // ctx.egraph_pass(module.isa()).unwrap();

    module
        .define_function(func_id, &mut ctx)
        .unwrap();
}

#[extension_trait]
impl ByteCode for [u8] {
    fn byte_code(&self) -> ByteCodeParser {
        ByteCodeParser { input: self }
    }
}

struct ByteCodeParser<'a> {
    input: &'a [u8],
}
impl<'a> ByteCodeParser<'a> {
    fn done(&self) -> bool {
        self.input.is_empty()
    }
    fn advance_by(&mut self, n: usize) {
        self.input = &self.input[n..];
    }
    fn eat_byte(&mut self) -> Option<u8> {
        if self.done() {
            return None;
        }
        let byte = self.input[0];
        self.advance_by(1);
        Some(byte)
    }
    fn eat_i64(&mut self) -> Option<i64> {
        if self.input.len() < 8 {
            panic!("binary incomplete");
        }
        let word = self.input.word_at(0);
        self.advance_by(8);
        Some(word)
    }
    fn eat_usize(&mut self) -> Option<usize> {
        self.eat_i64().map(|word| word as usize)
    }
    fn eat_reg(&mut self) -> Reg {
        let byte = self.eat_byte().expect("expected register");
        Reg::try_from(byte & 0x0f).unwrap()
    }
    fn eat_regs(&mut self) -> (Reg, Reg) {
        let byte = self.eat_byte().expect("expected registers");
        (Reg::try_from(byte & 0x0f).unwrap(), Reg::try_from(byte >> 4 & 0x0f).unwrap())
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

#[derive(Clone, Copy)]
enum Reg { SP, ST, A, B, C, D, E, F }

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
            opcode => panic!("unknown opcode {}", opcode),
        })
    }
}

impl From<Reg> for Variable {
    fn from(value: Reg) -> Self {
        Variable::new(match value {
            Reg::SP => 0,
            Reg::ST => 1,
            Reg::A => 2,
            Reg::B => 3,
            Reg::C => 4,
            Reg::D => 5,
            Reg::E => 6,
            Reg::F => 7,
        })
    }
}
