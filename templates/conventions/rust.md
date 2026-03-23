## Rust Conventions

When writing or modifying Rust code in this project:

### Dependencies
- Before using any crate, verify it is in `Cargo.toml` [dependencies]
- Never add new dependencies without strong justification
- Use `std` library alternatives when available

### Testing
- Write tests in `#[cfg(test)] mod tests` blocks inside the source file, or in `tests/` directory for integration tests
- Follow existing test naming: `#[test] fn test_*` or `#[test] fn it_*`
- Use `assert_eq!`, `assert!`, `assert_ne!` — not `println!` checks
- Mock with trait objects or dependency injection, not test-only crate features

### Error Handling
- Use `Result<T, E>` with custom error types, not `.unwrap()` in library code
- `.unwrap()` is acceptable in tests and examples only
- Prefer `?` operator over explicit `match` for error propagation

### Security
- Use `&str` slicing carefully — validate UTF-8 boundaries
- Avoid `unsafe` blocks unless strictly necessary and well-documented
