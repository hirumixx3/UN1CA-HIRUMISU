#!/usr/bin/env python3

from pathlib import Path
import hashlib
import re
import sys


def find_rune(decoded: Path) -> Path:
    matches = []

    for candidate in decoded.rglob("Rune.smali"):
        text = candidate.read_text(
            encoding="utf-8",
            errors="strict",
        )

        if (
            ".class " in text
            and "Lcom/samsung/android/settings/intelligence/Rune;"
            in text
        ):
            matches.append(candidate)

    if len(matches) != 1:
        print(
            "ERRO: esperado exatamente um Rune.smali de "
            "SecSettingsIntelligence; encontrados "
            f"{len(matches)}.",
            file=sys.stderr,
        )

        for match in matches:
            print(f"  - {match}", file=sys.stderr)

        raise SystemExit(2)

    return matches[0]


def extract_method(text: str):
    signature = re.search(
        r"^\.method[^\n]*\b"
        r"getSupportSearchInAppAssist\(\)Z\s*$",
        text,
        flags=re.MULTILINE,
    )

    if not signature:
        raise SystemExit(
            "ERRO: getSupportSearchInAppAssist()Z "
            "não foi encontrado em Rune.smali."
        )

    end = text.find(
        "\n.end method",
        signature.end(),
    )

    if end < 0:
        raise SystemExit(
            "ERRO: final de "
            "getSupportSearchInAppAssist()Z não encontrado."
        )

    end += len("\n.end method")

    return signature.start(), end, text[signature.start():end]


def find_parse_int_literal(method: str):
    lines = method.splitlines(keepends=True)
    candidates = []

    const_pattern = re.compile(
        r'^(?P<indent>\s*)'
        r'(?P<opcode>const-string(?:/jumbo)?)\s+'
        r'(?P<register>[vp]\d+),\s*'
        r'"(?P<value>(?:\\.|[^"])*)"'
        r'(?P<ending>\s*)$'
    )

    for index, raw_line in enumerate(lines):
        line = raw_line.rstrip("\n")
        match = const_pattern.match(line)

        if not match:
            continue

        register = match.group("register")

        parse_pattern = re.compile(
            r"invoke-static\s+\{\s*"
            + re.escape(register)
            + r"\s*\},\s*"
            r"Ljava/lang/Integer;->parseInt"
            r"\(Ljava/lang/String;\)I"
        )

        for lookahead in range(
            index + 1,
            min(len(lines), index + 10),
        ):
            if parse_pattern.search(lines[lookahead]):
                candidates.append(
                    (
                        index,
                        match,
                    )
                )
                break

    if len(candidates) != 1:
        print(
            "ERRO: esperado exatamente um const-string "
            "alimentando Integer.parseInt() em "
            "getSupportSearchInAppAssist(); encontrados "
            f"{len(candidates)}.",
            file=sys.stderr,
        )

        print(
            "\n===== MÉTODO ATUAL =====",
            file=sys.stderr,
        )
        print(method, file=sys.stderr)

        raise SystemExit(3)

    return lines, candidates[0]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(
            "Uso: apply_semantic_search_android17.py "
            "<SecSettingsIntelligence.apk decompilado>"
        )

    decoded = Path(sys.argv[1]).resolve()

    if not decoded.is_dir():
        raise SystemExit(
            f"ERRO: diretório decompilado não encontrado:\n{decoded}"
        )

    rune = find_rune(decoded)

    original = rune.read_text(
        encoding="utf-8",
        errors="strict",
    )

    method_start, method_end, method = extract_method(original)
    lines, candidate = find_parse_int_literal(method)

    line_index, match = candidate
    current_value = match.group("value")
    register = match.group("register")

    print(
        "Semantic Search Android 17:"
        f"\n  Rune: {rune.relative_to(decoded)}"
        f"\n  Método: getSupportSearchInAppAssist()Z"
        f"\n  Registrador: {register}"
        f'\n  Valor atual: "{current_value}"'
    )

    if current_value == "400":
        print(
            "  Estado: versão 400 já configurada; "
            "nenhuma alteração necessária."
        )
    else:
        newline = "\n" if lines[line_index].endswith("\n") else ""

        lines[line_index] = (
            f'{match.group("indent")}'
            f'{match.group("opcode")} '
            f'{register}, "400"'
            f'{match.group("ending")}'
            f'{newline}'
        )

        modified_method = "".join(lines)

        modified = (
            original[:method_start]
            + modified_method
            + original[method_end:]
        )

        rune.write_text(
            modified,
            encoding="utf-8",
        )

        print(
            f'  Estado: valor "{current_value}" '
            'substituído por "400".'
        )

    final = rune.read_text(
        encoding="utf-8",
        errors="strict",
    )

    _, _, final_method = extract_method(final)
    _, final_candidate = find_parse_int_literal(final_method)
    _, final_match = final_candidate

    if final_match.group("value") != "400":
        raise SystemExit(
            "ERRO: validação final falhou; "
            "getSupportSearchInAppAssist() não usa 400."
        )

    digest = hashlib.sha256(
        rune.read_bytes()
    ).hexdigest()

    print("  Validação: Integer.parseInt(\"400\") presente.")
    print(f"  SHA-256 Rune.smali: {digest}")


if __name__ == "__main__":
    main()
