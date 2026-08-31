#!/usr/bin/env python3
"""Command-position tokens in the packaged migrant script.

A drift tripwire, not a classifier: telling a real command from a word in an
error message cannot be done reliably here, and guessing wrong is how a missing
runtime dep ships. checks/cli-tokens.txt snapshots the whole set; the check
fires on CHANGE, so prose false positives sit there harmlessly.
"""

import re
import sys

# Shell keywords and builtins never resolve on PATH.
# Prose inside error messages. Listed to keep the snapshot readable.
PROSE = set(
    """a an and are as at be but by can does for from has have here how in into is
    it its may no not of on or so that the then there these this to use used using
    was when where which will with you your afterward already always instead only
    otherwise same self still such than them they what while without""".split()
)

BUILTINS = set(
    """if then else elif fi for while do done case esac in function return break
    continue exit local declare typeset readonly export unset shift eval exec set
    trap wait echo printf read test true false source cd pwd let time until select
    coproc mapfile readarray getopts hash type ulimit umask alias unalias jobs kill
    bg fg disown suspend caller builtin enable logout help history fc dirs pushd
    popd shopt complete compgen compopt""".split()
)

# (?!=) drops assignments: `dest_dir=$(...)` is command-position by shape, and
# the churn would train a reader to rubber-stamp the diff.
CMD_POS = re.compile(
    r"(?:^|[|;&(]|\|\||&&|\$\(|\bthen\b|\belse\b|\bdo\b|\bif\b|\bexec\b"
    r"|\bcommand\b|\bsudo\b)\s*([a-z][a-z0-9_.\-]{1,20})\b(?!=)",
    re.M,
)
FUNC_DEF = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", re.M)

# A preflight names its command as an argument, not at command position. `zstd`
# is exactly that: only ever inside a quoted --use-compress-program and a
# `command -v` guard.
PREFLIGHT = re.compile(
    r"\b(?:command\s+-[vV]|hash|type\s+-[pP])\s+([a-z][a-z0-9_.\-]{1,20})\b"
)


def tokens(script: str) -> set[str]:
    body = "\n".join(l for l in script.split("\n") if not l.lstrip().startswith("#"))
    funcs = set(FUNC_DEF.findall(body))
    found = {m.group(1) for m in CMD_POS.finditer(body)}
    found |= {m.group(1) for m in PREFLIGHT.finditer(body)}
    return found - BUILTINS - PROSE - funcs


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        for tok in sorted(tokens(fh.read())):
            print(tok)
