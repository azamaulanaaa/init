//! A minimal Rust starter library.
//!
//! The library holds the greeting that the binary prints.

/// Return the greeting that the starter prints.
pub fn greeting() -> &'static str {
    "Hello from the Rust starter!"
}

#[cfg(test)]
mod tests {
    use super::greeting;

    #[test]
    fn greeting_contains_rust_starter() {
        assert_eq!(greeting(), "Hello from the Rust starter!");
    }
}
