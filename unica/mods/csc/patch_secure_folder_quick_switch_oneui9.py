#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


PACKAGE = "com.samsung.android.aliveprivacy"

HAS_PACKAGE = (
    "Lcom/android/settings/Utils;->hasPackage("
    "Landroid/content/Context;"
    "Ljava/lang/String;)Z"
)

USEFUL_MARKER = (
    "# UN1CA_ONEUI9_SECURE_FOLDER_SEARCH_ENABLED"
)

FUNCTION_MARKER = (
    "# UN1CA_ONEUI9_SECURE_FOLDER_QUICK_SWITCH_ENABLED"
)


def abort(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def find_one(root: Path, suffix: str) -> Path:
    matches = [
        path
        for path in root.rglob(Path(suffix).name)
        if path.as_posix().endswith(suffix)
    ]

    if len(matches) != 1:
        abort(
            f"esperava exatamente uma classe terminando em "
            f"{suffix}; encontrei {len(matches)}"
        )

    return matches[0]


def next_instruction(
    lines: list[str],
    start: int,
) -> int | None:
    for index in range(start + 1, len(lines)):
        stripped = lines[index].strip()

        if (
            not stripped
            or stripped.startswith("#")
            or stripped.startswith(".line")
            or stripped.startswith(".local")
            or stripped.startswith(".restart local")
        ):
            continue

        return index

    return None


def containing_method(
    lines: list[str],
    target: int,
) -> tuple[int, int]:
    start = None

    for index in range(target, -1, -1):
        if lines[index].strip().startswith(".method"):
            start = index
            break

    if start is None:
        abort(f"método não encontrado para linha {target + 1}")

    end = None

    for index in range(target, len(lines)):
        if lines[index].strip() == ".end method":
            end = index
            break

    if end is None:
        abort(f".end method não encontrado para linha {target + 1}")

    return start, end


def parse_const_string(
    line: str,
    expected: str,
) -> str | None:
    match = re.match(
        rf'^\s*const-string(?:/jumbo)?\s+'
        rf'([vp]\d+),\s*"{re.escape(expected)}"\s*$',
        line,
    )

    return match.group(1) if match else None


def parse_move_result(line: str) -> str | None:
    match = re.match(
        r"^\s*move-result(?:/from16)?\s+([vp]\d+)\s*$",
        line,
    )

    return match.group(1) if match else None


def patch_usefulfeature(path: Path) -> None:
    lines = path.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    text = "".join(lines)

    if USEFUL_MARKER in text:
        print(f"OK: Usefulfeature já corrigida: {path}")
        return

    package_indexes = [
        index
        for index, line in enumerate(lines)
        if PACKAGE in line
    ]

    if len(package_indexes) != 1:
        abort(
            f"{path}: esperava uma referência a {PACKAGE}; "
            f"encontrei {len(package_indexes)}"
        )

    package_index = package_indexes[0]
    package_register = parse_const_string(
        lines[package_index].strip(),
        PACKAGE,
    )

    if package_register is None:
        abort(
            f"{path}: const-string do pacote não reconhecida"
        )

    invoke_index = next_instruction(lines, package_index)
    move_index = (
        next_instruction(lines, invoke_index)
        if invoke_index is not None
        else None
    )
    branch_index = (
        next_instruction(lines, move_index)
        if move_index is not None
        else None
    )

    if None in (invoke_index, move_index, branch_index):
        abort(f"{path}: sequência hasPackage incompleta")

    assert invoke_index is not None
    assert move_index is not None
    assert branch_index is not None

    if HAS_PACKAGE not in lines[invoke_index]:
        abort(
            f"{path}: chamada Utils.hasPackage não encontrada "
            f"depois de {PACKAGE}"
        )

    result_register = parse_move_result(
        lines[move_index].strip()
    )

    if result_register != package_register:
        abort(
            f"{path}: move-result usa {result_register}, "
            f"mas o pacote usa {package_register}"
        )

    branch_match = re.match(
        rf"^\s*if-eqz\s+{re.escape(result_register)},\s*"
        r"(:[A-Za-z0-9_.$-]+)\s*$",
        lines[branch_index],
    )

    if branch_match is None:
        abort(
            f"{path}: branch if-eqz após hasPackage "
            "não reconhecida"
        )

    label = branch_match.group(1)

    # Labels smali só precisam ser únicos dentro do método.
    # :cond_1 pode existir novamente em outros métodos da classe.
    method_start, method_end = containing_method(
        lines,
        package_index,
    )

    label_definitions = [
        index
        for index in range(method_start, method_end + 1)
        if lines[index].strip() == label
    ]

    label_references = [
        index
        for index in range(method_start, method_end + 1)
        if index not in label_definitions
        and re.search(
            rf"(?<![A-Za-z0-9_.$-])"
            rf"{re.escape(label)}"
            rf"(?![A-Za-z0-9_.$-])",
            lines[index],
        )
    ]

    if len(label_definitions) != 1:
        abort(
            f"{path}: definição de {label} apareceu "
            f"{len(label_definitions)} vezes"
        )

    if label_references != [branch_index]:
        abort(
            f"{path}: {label} possui outras referências; "
            "remoção recusada"
        )

    label_index = label_definitions[0]

    if label_index <= branch_index:
        abort(f"{path}: label de saída está antes do branch")

    nearby = "".join(
        lines[label_index:min(len(lines), label_index + 12)]
    )

    if '"function_key_setting"' not in nearby:
        abort(
            f"{path}: {label} não antecede "
            "function_key_setting como esperado"
        )

    indent = lines[package_index][
        :len(lines[package_index])
        - len(lines[package_index].lstrip())
    ]

    lines[package_index] = f"{indent}{USEFUL_MARKER}\n"
    lines[invoke_index] = ""
    lines[move_index] = ""
    lines[branch_index] = ""
    lines[label_index] = ""

    result = "".join(lines)

    if PACKAGE in result:
        abort(
            f"{path}: verificação do pacote permaneceu "
            "após o patch"
        )

    path.write_text(result, encoding="utf-8")

    print(
        "OK: restrição de busca do Secure Folder removida de "
        f"{path}"
    )


def patch_function_key(path: Path) -> None:
    lines = path.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    text = "".join(lines)

    if FUNCTION_MARKER in text:
        print(f"OK: FunctionKeyUtils já corrigida: {path}")
        return

    def previous_meaningful(
        start: int,
        lower_bound: int,
    ) -> list[tuple[int, str]]:
        result: list[tuple[int, str]] = []

        for index in range(start - 1, lower_bound, -1):
            instruction = lines[index].strip()

            if (
                not instruction
                or instruction.startswith("#")
                or instruction.startswith(".line")
                or instruction.startswith(".local")
                or instruction.startswith(".restart local")
            ):
                continue

            result.append((index, instruction))

            if len(result) >= 15:
                break

        return result

    def next_meaningful(
        start: int,
        upper_bound: int,
    ) -> tuple[int, str] | None:
        for index in range(start + 1, upper_bound):
            instruction = lines[index].strip()

            if (
                not instruction
                or instruction.startswith("#")
                or instruction.startswith(".line")
                or instruction.startswith(".local")
                or instruction.startswith(".restart local")
            ):
                continue

            return index, instruction

        return None

    candidates: list[
        tuple[int, int, int, str, str]
    ] = []

    has_package_calls: list[int] = []

    for invoke_index, line in enumerate(lines):
        if HAS_PACKAGE not in line:
            continue

        has_package_calls.append(invoke_index)

        method_start, method_end = containing_method(
            lines,
            invoke_index,
        )

        previous = previous_meaningful(
            invoke_index,
            method_start,
        )

        object_getclass = [
            (index, instruction)
            for index, instruction in previous
            if (
                instruction.startswith("invoke-virtual")
                and
                "Ljava/lang/Object;->getClass()"
                "Ljava/lang/Class;"
                in instruction
            )
        ]

        if not object_getclass:
            continue

        # O getClass deve estar próximo da chamada hasPackage,
        # conforme o hunk original.
        getclass_index = object_getclass[0][0]

        if invoke_index - getclass_index > 10:
            continue

        move_entry = next_meaningful(
            invoke_index,
            method_end,
        )

        if move_entry is None:
            continue

        move_index, move_instruction = move_entry

        move_match = re.fullmatch(
            r"move-result(?:/from16)?\s+([vp]\d+)",
            move_instruction,
        )

        if move_match is None:
            continue

        result_register = move_match.group(1)

        branch_entry = next_meaningful(
            move_index,
            method_end,
        )

        if branch_entry is None:
            continue

        branch_index, branch_instruction = branch_entry

        branch_match = re.fullmatch(
            rf"if-nez\s+{re.escape(result_register)},\s*"
            r"(:[A-Za-z0-9_.$-]+)",
            branch_instruction,
        )

        if branch_match is None:
            continue

        candidates.append(
            (
                invoke_index,
                move_index,
                branch_index,
                result_register,
                branch_match.group(1),
            )
        )

    if len(candidates) != 1:
        print(
            "Chamadas Utils.hasPackage encontradas: "
            + (
                ", ".join(
                    str(index + 1)
                    for index in has_package_calls
                )
                if has_package_calls
                else "nenhuma"
            )
        )

        for index in has_package_calls:
            method_start, method_end = containing_method(
                lines,
                index,
            )

            print()
            print(
                f"--- contexto da linha {index + 1} ---"
            )

            for context_index in range(
                max(method_start, index - 8),
                min(method_end + 1, index + 10),
            ):
                print(
                    f"{context_index + 1}: "
                    f"{lines[context_index].rstrip()}"
                )

        abort(
            f"{path}: esperava exatamente uma sequência "
            "Object.getClass() -> Utils.hasPackage() -> "
            "move-result -> if-nez; encontrei "
            f"{len(candidates)}"
        )

    (
        invoke_index,
        move_index,
        branch_index,
        result_register,
        branch_label,
    ) = candidates[0]

    indent = lines[invoke_index][
        :len(lines[invoke_index])
        - len(lines[invoke_index].lstrip())
    ]

    original_invoke = lines[invoke_index].strip()

    lines[invoke_index] = (
        f"{indent}{FUNCTION_MARKER}\n"
        f"{indent}const/4 {result_register}, 0x1\n"
    )

    lines[move_index] = ""

    result = "".join(lines)

    if FUNCTION_MARKER not in result:
        abort(f"{path}: marcador do patch não foi gravado")

    # Confirma que imediatamente após o valor verdadeiro
    # continua existindo o branch original.
    marker_index = next(
        index
        for index, line in enumerate(lines)
        if FUNCTION_MARKER in line
    )

    nearby = "".join(
        lines[marker_index:marker_index + 8]
    )

    expected_branch = (
        f"if-nez {result_register}, {branch_label}"
    )

    if expected_branch not in nearby:
        abort(
            f"{path}: branch {expected_branch} não foi "
            "preservado após o patch"
        )

    path.write_text(
        result,
        encoding="utf-8",
    )

    print(
        "OK: verificação hasPackage do quick switch "
        f"forçada para true na linha {invoke_index + 1}"
    )

    print(f"Chamada substituída: {original_invoke}")
    print(
        "OK: quick switch do Secure Folder forçado "
        f"como disponível em {path}"
    )


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: patch_secure_folder_quick_switch_oneui9.py "
            "<SecSettings.apk decodificado>"
        )

    root = Path(sys.argv[1])

    if not root.is_dir():
        abort(f"SecSettings decodificado ausente: {root}")

    useful = find_one(
        root,
        "com/samsung/android/settings/usefulfeature/"
        "Usefulfeature$1.smali",
    )

    function_key = find_one(
        root,
        "com/samsung/android/settings/usefulfeature/"
        "functionkey/FunctionKeyUtils.smali",
    )

    print(f"Usefulfeature detectada: {useful}")
    print(f"FunctionKeyUtils detectada: {function_key}")

    patch_usefulfeature(useful)
    patch_function_key(function_key)

    final_useful = useful.read_text(
        encoding="utf-8",
        errors="strict",
    )

    final_function = function_key.read_text(
        encoding="utf-8",
        errors="strict",
    )

    failures = []

    if USEFUL_MARKER not in final_useful:
        failures.append("marcador Usefulfeature ausente")

    if FUNCTION_MARKER not in final_function:
        failures.append("marcador FunctionKeyUtils ausente")

    if PACKAGE in final_useful:
        failures.append(
            "restrição aliveprivacy permaneceu em Usefulfeature"
        )

    if failures:
        abort(
            "validação do quick switch falhou: "
            + "; ".join(failures)
        )

    for reject in root.rglob("*.rej"):
        reject.unlink()

    print(
        "OK: quick switch do Secure Folder "
        "completamente aplicado"
    )


if __name__ == "__main__":
    main()
