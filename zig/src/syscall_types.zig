// Syscalls that want to return values in registers can use these types.

pub const ZeroValues = void;
pub const OneValue = i64;
pub const TwoValues = extern struct { a: i64, b: i64 };
