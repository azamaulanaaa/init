fn greeting() -> &'static str {
    "Hello from the Rust starter!"
}

fn main() {
    println!("{}", greeting());
}

#[cfg(test)]
mod tests {
    use super::greeting;

    #[test]
    fn greeting_contains_rust_starter() {
        assert_eq!(greeting(), "Hello from the Rust starter!");
    }
}
