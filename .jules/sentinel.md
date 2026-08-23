## 2024-05-24 - Investigating eval vulnerability in enforce_config_ceilings
**Vulnerability:** The function `enforce_config_ceilings` was using variable indirection pattern in older scripts `local _cur_budget="${!_var_budget}"` and `printf -v "$_var_budget"`.
**Learning:** Found that these manual references without `declare -n` can open up command injection if variable name is controlled by attacker.
**Prevention:** Make sure to use `declare -n` nameref instead of `eval`, `${!var}` or `printf -v`.
