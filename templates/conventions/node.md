## Node.js / TypeScript Conventions

When writing or modifying code in this project:

### Imports
- Check existing files to see if the project uses ES modules (`import/export`) or CommonJS (`require/module.exports`)
- Check `package.json` for `"type": "module"` to determine module system
- Before importing any package, verify it is in `package.json` dependencies or devDependencies
- If a package is NOT available, use `jest.mock()` or `vi.mock()` instead — never add new dependencies

### Testing
- Check which test runner is configured: look for `jest.config.*`, `vitest.config.*`, or `"test"` script in `package.json`
- For projects with NO test runner: use Node's built-in `node:test` module (zero dependencies)
- Follow existing test file naming: `*.test.ts`, `*.spec.ts`, or `__tests__/*.ts`
- Use `jest.mock()` or `vi.mock()` for mocking — not real imports of external services
- For TypeScript projects without test runner configured: write tests as `.mjs` files using `node:test` to avoid needing `ts-node`

### TypeScript
- Respect `strict` mode if `tsconfig.json` has it enabled
- Use `as const` assertions and discriminated unions over type casting

### Security
- Sanitize HTML with allowlist-based approaches, not blocklist regex
- Use specific `remotePatterns` in `next.config.ts` instead of wildcard `hostname: '**'`
- Always sanitize user-provided or external HTML content before rendering
