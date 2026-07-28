#!/usr/bin/env python3
from pathlib import Path
import os
import re
import sys

def abort(message):
    raise SystemExit("ERRO: " + message)

if len(sys.argv) != 2:
    abort("informe ASKSManagerService.smali")

path = Path(sys.argv[1])

if not path.is_file():
    abort(f"arquivo não encontrado: {path}")

text = path.read_text(encoding="utf-8")

GET_TWO = (
    "Landroid/os/SystemProperties;->get"
    "(Ljava/lang/String;Ljava/lang/String;)"
    "Ljava/lang/String;"
)

# Estrutura dos hunks 1 e 2.
two_argument_pattern = re.compile(
    r'(?m)^(?P<i>[ \t]*)const-string/jumbo '
    r'(?P<key>v\d+), "ro\.build\.official\.release"\n\n'
    r'(?P=i)const-string/jumbo '
    r'(?P<default>v\d+), "false"\n\n'
    r'(?P=i)invoke-static '
    r'\{(?P=key), (?P=default)\}, '
    + re.escape(GET_TWO) +
    r'\n\n'
    r'(?P=i)move-result-object (?P=key)\n\n'
    r'(?P=i)const-string/jumbo '
    r'(?P=default), "true"\n'
)

def replace_two(match):
    indent = match.group("i")
    key = match.group("key")
    default = match.group("default")

    return (
        f'{indent}const-string/jumbo {key}, '
        f'"persist.sys.unica.asks"\n\n'
        f'{indent}const-string/jumbo {default}, "true"\n\n'
        f'{indent}invoke-static {{{key}, {default}}}, '
        f'{GET_TWO}\n\n'
        f'{indent}move-result-object {key}\n'
    )

text, converted_two = two_argument_pattern.subn(
    replace_two,
    text,
)

# Estrutura do hunk 3.
one_argument_pattern = re.compile(
    r'(?m)^(?P<i>[ \t]*)const-string/jumbo '
    r'(?P<key>v\d+), "ro\.build\.official\.release"\n\n'
    r'(?P=i)invoke-static \{(?P=key)\}, '
    r'Landroid/os/SystemProperties;->get'
    r'\(Ljava/lang/String;\)Ljava/lang/String;\n\n'
    r'(?P=i)move-result-object (?P=key)\n\n'
    r'(?P=i)const-string/jumbo '
    r'(?P<default>v\d+), "true"\n'
)

def replace_one(match):
    indent = match.group("i")
    key = match.group("key")
    default = match.group("default")

    return (
        f'{indent}const-string/jumbo {key}, '
        f'"persist.sys.unica.asks"\n\n'
        f'{indent}const-string/jumbo {default}, "true"\n\n'
        f'{indent}invoke-static {{{key}, {default}}}, '
        f'{GET_TWO}\n\n'
        f'{indent}move-result-object {key}\n'
    )

text, converted_one = one_argument_pattern.subn(
    replace_one,
    text,
)

if '"ro.build.official.release"' in text:
    abort(
        "a propriedade antiga ainda aparece em ASKSManagerService"
    )

validation_pattern = re.compile(
    r'(?m)^[ \t]*const-string/jumbo '
    r'(?P<key>v\d+), "persist\.sys\.unica\.asks"\n\n'
    r'[ \t]*const-string/jumbo '
    r'(?P<default>v\d+), "true"\n\n'
    r'[ \t]*invoke-static '
    r'\{(?P=key), (?P=default)\}, '
    + re.escape(GET_TWO) +
    r'\n\n'
    r'[ \t]*move-result-object (?P=key)$'
)

validated = list(validation_pattern.finditer(text))

if len(validated) != 3:
    abort(
        "esperadas 3 verificações completas de "
        "persist.sys.unica.asks; encontradas: "
        + str(len(validated))
    )

tmp = path.with_name(path.name + ".tmp")
tmp.write_text(text, encoding="utf-8")
os.replace(tmp, path)

print(
    "ASKS validado: 3 verificações usam "
    "persist.sys.unica.asks com padrão true "
    f"(convertidos agora: {converted_two + converted_one})"
)
