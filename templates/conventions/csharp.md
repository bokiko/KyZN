## C# / .NET Conventions

When writing or modifying C# code in this project:

### Dependencies
- Before using any package, verify it is in a `*.csproj` `<PackageReference>` element
- Never add new NuGet packages without strong justification
- Prefer BCL (`System.*`) types over third-party equivalents when available

### Testing
- Write tests in a separate `*.Tests.csproj` project, mirroring the source namespace
- Follow existing test framework: `[Fact]` / `[Theory]` (xUnit) or `[Test]` (NUnit) — match what the project already uses
- Name tests `MethodName_Scenario_ExpectedBehavior`
- Use `Assert.Equal`, `Assert.True`, `Assert.Throws<T>` — not `Console.WriteLine` checks
- Mock with interfaces and a DI container or hand-rolled fakes; prefer constructor injection

### Error Handling
- Throw specific exception types (`ArgumentNullException`, `InvalidOperationException`) — not bare `Exception`
- Never `catch (Exception)` and swallow silently; either rethrow with `throw;` or wrap with context
- Use `ConfigureAwait(false)` in library code; omit in app code unless there is a captured context concern
- Prefer `Try*` patterns (`int.TryParse`) over try/catch on hot paths

### Style
- Follow `dotnet format` (run before commit)
- Nullable reference types enabled — annotate `T?` and avoid `!` null-forgiving except in tests
- Use `var` for locals when the type is obvious from the right-hand side; explicit type otherwise
- Public APIs need XML doc comments (`/// <summary>`)
