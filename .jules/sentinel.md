## 2026-03-20 - [Scope Leakage & JQ Injection in Nameref Loops]
**Vulnerability:** Bash loops over namerefs (e.g., `local -n _wh_fields`) leaked their iterator variables into the calling scope. Furthermore, arbitrary keys could be passed into `jq --arg` which suppresses errors silently if an invalid key name is used.
**Learning:** Namerefs can inadvertently poison the calling function's variable environment if the loop iterator isn't explicitly declared as `local`. Moreover, unsanitized map keys should not be blindly passed as `jq` arguments.
**Prevention:** Always declare loop iterator variables as `local` (e.g., `local key; for key in ...`). Apply regex validation (e.g., `^[a-zA-Z_][a-zA-Z0-9_]*$`) to keys before interpolating them as tool arguments.
