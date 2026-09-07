## 2026-03-20 - [Scope Leakage in Nameref Loops]
**Vulnerability:** Bash loops over namerefs (e.g., `local -n _wh_fields`) leaked their iterator variables into the calling scope because the iterator was not declared as local.
**Learning:** Namerefs can inadvertently poison the calling function's variable environment if the loop iterator isn't explicitly declared as `local`.
**Prevention:** Always declare loop iterator variables as `local` (e.g., `local key; for key in ...`).
