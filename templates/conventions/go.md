## Go Conventions

When writing or modifying Go code in this project:

### Dependencies
- Before importing any package, verify it is in `go.mod`
- Never add new dependencies without strong justification
- Prefer standard library packages when available

### Testing
- Write tests in `*_test.go` files in the same package
- Follow existing test naming: `func TestXxx(t *testing.T)`
- Use `t.Run()` for subtests
- Use table-driven tests when testing multiple inputs
- Use interfaces for mocking — create test doubles, not mocking frameworks

### Error Handling
- Always check and handle errors: `if err != nil { return err }`
- Never use `_` to discard errors in production code
- Wrap errors with context: `fmt.Errorf("doing X: %w", err)`

### Style
- Follow `gofmt` formatting (automatic)
- Use short variable names in small scopes, descriptive names in larger scopes
- Exported functions need doc comments starting with the function name
