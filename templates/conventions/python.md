## Python Conventions

When writing or modifying Python code in this project:

### Imports
- Check existing test files to see what import style the project uses (e.g., `from src.core import X` vs `from src.app import X`)
- Before importing any package, verify it is installed: check `requirements.txt`, `pyproject.toml`, or run `pip list | grep <pkg>`
- If a package is NOT installed, use `unittest.mock` instead — never add new dependencies

### Testing
- Use `pytest` as the test framework (unless the project uses something else — check for `conftest.py`, `pytest.ini`)
- Follow the project's existing test file naming: check if tests are in `tests/test_*.py` or `*_test.py`
- Look at existing test fixtures before creating new ones — reuse `conftest.py` fixtures
- Use `unittest.mock.patch` and `MagicMock` for mocking — not real imports of external packages
- If test classes use `object.__new__(ClassName)` to avoid `__init__` side effects, follow that pattern
- Use `asyncio.run()` for running async tests, NOT `asyncio.get_event_loop().run_until_complete()`

### Error Handling
- Use specific exception types: `except (OSError, ValueError):` not bare `except:`
- Never catch `KeyboardInterrupt` or `SystemExit` accidentally

### Security Fixes
- When fixing command injection: use `shlex.split()` + `shell=False`, or allowlists
- When fixing path traversal: use `Path.resolve()` + `.is_relative_to()` checks
- When adding input validation: compile regexes at module level, not inside functions
