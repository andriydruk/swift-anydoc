// Dump WHATWG decode tables for the legacy multi-byte CJK code pages, using
// encoding_rs itself so the Swift port cannot drift from the reference.
fn main() {
    for (label, enc) in [
        ("shift_jis", encoding_rs::SHIFT_JIS),
        ("euc_kr", encoding_rs::EUC_KR),
        ("gbk", encoding_rs::GBK),
        ("big5", encoding_rs::BIG5),
    ] {
        // Single bytes.
        let mut singles = Vec::new();
        for b in 0u16..=0xFF {
            let bytes = [b as u8];
            let (text, _) = enc.decode_without_bom_handling(&bytes);
            let scalars: Vec<char> = text.chars().collect();
            let v = if scalars.len() == 1 && scalars[0] != '\u{FFFD}' {
                scalars[0] as u32
            } else {
                0
            };
            singles.push(v);
        }
        println!("#SINGLE {label}");
        for v in &singles {
            println!("{v}");
        }
        // Two-byte sequences: only lead bytes that decode to nothing alone.
        println!("#DOUBLE {label}");
        for lead in 0x81u16..=0xFEu16 {
            for trail in 0x00u16..=0xFFu16 {
                let bytes = [lead as u8, trail as u8];
                let (text, _) = enc.decode_without_bom_handling(&bytes);
                let scalars: Vec<char> = text.chars().collect();
                // One scalar, not a replacement, and not simply the two bytes
                // decoding independently.
                let v = if scalars.len() == 1 && scalars[0] != '\u{FFFD}' {
                    scalars[0] as u32
                } else {
                    0
                };
                if v != 0 {
                    println!("{lead} {trail} {v}");
                }
            }
        }
    }
}
