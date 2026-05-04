## Java / JVM Conventions

When writing or modifying Java code in this project:

### Dependencies
- Before using any library, verify it is declared in `pom.xml` (`<dependency>`) or `build.gradle{,.kts}` (`implementation` / `api` / `testImplementation`)
- Never add new dependencies without strong justification
- Prefer JDK standard library (`java.util.*`, `java.nio.*`) over third-party equivalents when available

### Testing
- Write tests under `src/test/java/` mirroring the production package layout
- Follow existing test framework: JUnit 5 (`@Test` from `org.junit.jupiter.api`) unless the project already uses JUnit 4 or TestNG
- Name tests `methodName_scenario_expectedBehavior` or `shouldDoXWhenY`
- Use AssertJ (`assertThat(...)`) or JUnit `Assertions.*` — not `System.out.println` checks
- Mock with Mockito (`@Mock`, `when(...).thenReturn(...)`); prefer constructor injection over field injection

### Error Handling
- Throw specific exception types (`IllegalArgumentException`, `IllegalStateException`) — not bare `RuntimeException` or `Exception`
- Never `catch (Exception e)` and swallow silently; either rethrow, wrap with context (`new XException("doing X", e)`), or log at the boundary
- Prefer checked exceptions only at API boundaries; convert to unchecked internally
- Use `Optional<T>` for return types that may be empty; never return `null` from public APIs

### Style
- Follow `mvn spotless:apply` or Gradle equivalent (Google Java Format / Palantir style — match project)
- Public APIs need Javadoc (`/** ... */`) including `@param` and `@return`
- Final fields and parameters where practical; avoid mutable static state
- Streams over manual loops only when they improve readability; avoid side effects inside `.map()` / `.filter()`
