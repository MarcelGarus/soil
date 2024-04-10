use crate::utils::WordFromByteSlice;

pub struct Binary {
    pub memory: Vec<u8>,
    pub byte_code: Vec<u8>,
    pub labels: Vec<(usize, String)>,
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

impl Binary {
    pub fn parse(bytes: &[u8]) -> Self {
        let mut binary = Self {
            memory: vec![],
            byte_code: vec![],
            labels: vec![],
        };
        let mut parser = Parser { input: bytes };
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
                    for _ in 0..section_len {
                        binary.byte_code.push(parser.eat_byte());
                    }
                }
                1 => {
                    // initial memory
                    for _ in 0..section_len {
                        binary.memory.push(parser.eat_byte());
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
                        binary.labels.push((pos, label));
                    }
                }
                _ => {
                    parser.advance_by(section_len);
                }
            }
        }

        binary
    }
}
