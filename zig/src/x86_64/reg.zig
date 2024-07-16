pub const Reg = enum {
    sp,
    st,
    a,
    b,
    c,
    d,
    e,
    f,

    pub fn parse(byte: u8) !Reg {
        return switch (byte) {
            0 => Reg.sp,
            1 => Reg.st,
            2 => Reg.a,
            3 => Reg.b,
            4 => Reg.c,
            5 => Reg.d,
            6 => Reg.e,
            7 => Reg.f,
            else => return error.UnknownRegister,
        };
    }

    pub fn to_byte(self: Reg) u8 {
        return @as(u8, @intFromEnum(self));
    }
};
