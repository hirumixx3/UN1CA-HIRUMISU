#!/usr/bin/env python3

from pathlib import Path
import os
import re
import sys

SIGNATURE = (
    "Lcom/android/server/pm/InstallPackageHelper;"
    "->setSigningDetailsWithCustomSignatures"
    "(Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "Landroid/content/pm/SigningDetails;)V"
)

METHOD_RE = re.compile(
    r"(?ms)^\.method [^\n]+\n.*?^\.end method$"
)

INVOKE_RE = re.compile(
    r"(?m)^(?P<indent>[ \t]*)"
    r"invoke-direct \{(?P<args>[^}]+)\}, "
    + re.escape(SIGNATURE)
    + r"$"
)


def register_is_high(register: str) -> bool:
    register = register.strip()

    if register.startswith("p"):
        return True

    match = re.fullmatch(r"v(\d+)", register)

    if not match:
        raise RuntimeError(
            f"Registrador desconhecido: {register}"
        )

    return int(match.group(1)) > 15


def patch_method(method: str) -> tuple[str, int]:
    calls = list(INVOKE_RE.finditer(method))

    invalid = []

    for call in calls:
        args = [
            item.strip()
            for item in call.group("args").split(",")
        ]

        if len(args) != 3:
            raise RuntimeError(
                "Esperava três argumentos no invoke-direct: "
                + call.group(0)
            )

        if any(register_is_high(arg) for arg in args):
            invalid.append((call, args))

    if not invalid:
        return method, 0

    locals_match = re.search(
        r"(?m)^(?P<indent>[ \t]*)"
        r"\.locals[ \t]+(?P<count>\d+)$",
        method,
    )

    if not locals_match:
        raise RuntimeError(
            "Método com invoke inválido não usa .locals"
        )

    old_locals = int(locals_match.group("count"))

    # Detecta referências absolutas aos registradores de parâmetros.
    explicit_v = [
        int(value)
        for value in re.findall(r"\bv(\d+)\b", method)
    ]

    if any(value >= old_locals for value in explicit_v):
        bad = sorted({
            value
            for value in explicit_v
            if value >= old_locals
        })

        raise RuntimeError(
            "Método usa aliases absolutos de parâmetros: "
            + ", ".join(f"v{x}" for x in bad)
        )

    base = old_locals

    if base + 2 > 65535:
        raise RuntimeError("Limite de registradores excedido")

    new_locals = old_locals + 3

    new_directive = (
        f"{locals_match.group('indent')}"
        f".locals {new_locals}"
    )

    method = (
        method[:locals_match.start()]
        + new_directive
        + method[locals_match.end():]
    )

    # Recalcula as ocorrências após alterar a diretiva .locals.
    calls = list(INVOKE_RE.finditer(method))
    replacements = []

    for call in calls:
        args = [
            item.strip()
            for item in call.group("args").split(",")
        ]

        if not any(register_is_high(arg) for arg in args):
            continue

        indent = call.group("indent")

        replacement = (
            f"{indent}move-object/16 v{base}, {args[0]}\n"
            f"\n"
            f"{indent}move-object/16 v{base + 1}, {args[1]}\n"
            f"\n"
            f"{indent}move-object/16 v{base + 2}, {args[2]}\n"
            f"\n"
            f"{indent}invoke-direct/range "
            f"{{v{base} .. v{base + 2}}}, {SIGNATURE}"
        )

        replacements.append(
            (call.start(), call.end(), replacement)
        )

    for start, end, replacement in reversed(replacements):
        method = (
            method[:start]
            + replacement
            + method[end:]
        )

    return method, len(replacements)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Uso: repair_signature_invokes_oneui9.py "
            "<services.jar decompilado>",
            file=sys.stderr,
        )
        return 2

    root = Path(sys.argv[1])

    matches = list(
        root.rglob("InstallPackageHelper.smali")
    )

    if len(matches) != 1:
        raise RuntimeError(
            "Esperava exatamente um InstallPackageHelper.smali; "
            f"encontrados: {len(matches)}"
        )

    path = matches[0]
    text = path.read_text(encoding="utf-8")

    methods = list(METHOD_RE.finditer(text))
    replacements = []
    total = 0

    for match in methods:
        method = match.group(0)

        if (
            "invoke-direct" not in method
            or SIGNATURE not in method
        ):
            continue

        patched, count = patch_method(method)

        if count:
            replacements.append(
                (match.start(), match.end(), patched)
            )
            total += count

    for start, end, patched in reversed(replacements):
        text = text[:start] + patched + text[end:]

    invalid_remaining = []

    for match in INVOKE_RE.finditer(text):
        args = [
            item.strip()
            for item in match.group("args").split(",")
        ]

        if any(register_is_high(arg) for arg in args):
            invalid_remaining.append(match.group(0))

    if invalid_remaining:
        raise RuntimeError(
            "Ainda existem invokes inválidos:\n"
            + "\n".join(invalid_remaining)
        )

    if total:
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)

        print(
            f"OK: {total} invoke(s) convertido(s) "
            "para invoke-direct/range"
        )
    else:
        print(
            "OK: nenhuma chamada inválida restante"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
