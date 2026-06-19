//! Validates that every WGSL shader parses and type-checks with naga.
//! Catches syntax/type errors in shaders (including post effects, which the
//! GIF capture tool skips) without needing a GPU.

use naga::valid::{Capabilities, ValidationFlags, Validator};
use std::fs;
use std::path::Path;

fn validate_dir(dir: &Path, files: &mut Vec<String>) {
    for entry in fs::read_dir(dir).expect("read shader dir") {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            validate_dir(&path, files);
        } else if path.extension().is_some_and(|e| e == "wgsl") {
            let src = fs::read_to_string(&path).expect("read shader");
            let module = naga::front::wgsl::parse_str(&src)
                .unwrap_or_else(|e| panic!("WGSL parse error in {}:\n{}", path.display(), e.emit_to_string(&src)));
            let mut validator = Validator::new(ValidationFlags::all(), Capabilities::all());
            validator
                .validate(&module)
                .unwrap_or_else(|e| panic!("WGSL validation error in {}: {:?}", path.display(), e));
            files.push(path.display().to_string());
        }
    }
}

#[test]
fn all_shaders_parse_and_validate() {
    let mut files = Vec::new();
    validate_dir(Path::new("shaders"), &mut files);
    assert!(!files.is_empty(), "expected to find WGSL shaders to validate");
    println!("validated {} WGSL shaders", files.len());
}
