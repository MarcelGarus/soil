use std::mem;

use extension_trait::extension_trait;

#[extension_trait]
pub impl WordFromByteSlice for [u8] {
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
