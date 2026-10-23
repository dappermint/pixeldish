# nix values to KYAML. An attrset { __raw = "..."; } is spliced in as-is, which
# is how a pattern copied out of the app goes in untouched
{ lib }:
let
  key = k: if builtins.match "[A-Za-z_][A-Za-z0-9_.-]*" k != null then k else builtins.toJSON k;
  emit =
    indent: v:
    let
      inner = indent + "  ";
    in
    if builtins.isAttrs v && v ? __raw then
      v.__raw
    else if builtins.isAttrs v then
      if v == { } then
        "{}"
      else
        "{\n"
        + lib.concatStrings (lib.mapAttrsToList (k: x: "${inner}${key k}: ${emit inner x},\n") v)
        + "${indent}}"
    else if builtins.isList v then
      if v == [ ] then "[]" else "[\n" + lib.concatMapStrings (x: "${inner}${emit inner x},\n") v + "${indent}]"
    else
      builtins.toJSON v;
in
emit ""
