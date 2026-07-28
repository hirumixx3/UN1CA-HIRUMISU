#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


OLD_APPLY = (
    "Lcom/android/server/pm/ScanPackageUtils;->applyPolicy("
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "ILcom/android/server/pm/pkg/AndroidPackage;Z)V"
)

NEW_APPLY = (
    "Lcom/android/server/pm/ScanPackageUtils;->applyPolicy("
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "ILcom/android/server/pm/pkg/AndroidPackage;"
    "Z[Landroid/content/pm/Signature;)V"
)

SET_SIGNING = (
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "->setSigningDetails("
    "Landroid/content/pm/SigningDetails;)"
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
)

SET_CUSTOM = (
    "Lcom/android/server/pm/ScanPackageUtils;"
    "->setCustomSignatures("
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "Lcom/android/server/pm/pkg/AndroidPackage;"
    "[Landroid/content/pm/Signature;"
    "[Landroid/content/pm/Signature;)V"
)

APPLY_WRAPPER_NAME = "applyPolicyWithCustomSignatures"

APPLY_WRAPPER_CALL = (
    "Lcom/android/server/pm/InstallPackageHelper;"
    f"->{APPLY_WRAPPER_NAME}("
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "ILcom/android/server/pm/pkg/AndroidPackage;Z)V"
)

SIGNING_WRAPPER_NAME = "setSigningDetailsWithCustomSignatures"

SIGNING_WRAPPER_CALL = (
    "Lcom/android/server/pm/InstallPackageHelper;"
    f"->{SIGNING_WRAPPER_NAME}("
    "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
    "Landroid/content/pm/SigningDetails;)V"
)


def abort(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def find_one(root: Path, filename: str) -> Path:
    matches = list(root.rglob(filename))

    if len(matches) != 1:
        abort(
            f"esperava exatamente um {filename}; "
            f"encontrei {len(matches)}"
        )

    return matches[0]


def method_ranges(
    lines: list[str],
) -> list[tuple[int, int, str]]:
    result: list[tuple[int, int, str]] = []
    start: int | None = None
    header = ""

    for index, line in enumerate(lines):
        stripped = line.strip()

        if stripped.startswith(".method"):
            if start is not None:
                abort("estrutura smali contém métodos aninhados")

            start = index
            header = stripped

        elif stripped == ".end method":
            if start is None:
                abort(".end method sem .method correspondente")

            result.append((start, index, header))
            start = None
            header = ""

    if start is not None:
        abort("método sem .end method")

    return result


def containing_method(
    ranges: list[tuple[int, int, str]],
    line_index: int,
) -> tuple[int, int, str]:
    for start, end, header in ranges:
        if start <= line_index <= end:
            return start, end, header

    abort(f"linha {line_index + 1} fora de qualquer método")


def parse_invoke_registers(
    line: str,
) -> tuple[str, list[str]]:
    match = re.match(
        r"^(\s*)invoke-[^\s]+\s+\{([^}]*)\},",
        line,
    )

    if not match:
        abort(
            "não foi possível interpretar a instrução: "
            + line.strip()
        )

    indent = match.group(1)
    raw = match.group(2).strip()

    if ".." in raw:
        abort(
            "invoke/range encontrado; alteração automática recusada"
        )

    registers = [
        register.strip()
        for register in raw.split(",")
        if register.strip()
    ]

    return indent, registers


def next_instruction(
    lines: list[str],
    index: int,
    method_end: int,
) -> str:
    for current in range(index + 1, method_end):
        value = lines[current].strip()

        if (
            value
            and not value.startswith("#")
            and not value.startswith(".line")
        ):
            return value

    return ""


def append_method(
    lines: list[str],
    method: str,
) -> None:
    if lines and lines[-1].strip():
        lines.append("\n")

    for line in method.strip("\n").splitlines():
        lines.append(line + "\n")

    lines.append("\n")


def repair_apply_policy(lines: list[str]) -> int:
    ranges = method_ranges(lines)

    old_calls = [
        index
        for index, line in enumerate(lines)
        if line.lstrip().startswith("invoke-static")
        and OLD_APPLY in line
    ]

    repaired = 0

    for index in old_calls:
        _, _, header = containing_method(ranges, index)

        if re.search(r"\bstatic\b", header):
            abort(
                "applyPolicy antiga encontrada em método estático; "
                "p0 não seria InstallPackageHelper"
            )

        indent, registers = parse_invoke_registers(lines[index])

        if len(registers) != 4:
            abort(
                "applyPolicy antiga deveria usar quatro registros; "
                f"encontrei {len(registers)}"
            )

        receiver_register = "p0"

        method_start = index
        while (
            method_start >= 0
            and not lines[method_start].startswith(".method ")
        ):
            method_start -= 1

        if method_start < 0:
            abort(
                "não encontrei o método da chamada applyPolicy"
            )

        method_header = lines[method_start]

        if " scanPackageForInitLI(" in method_header:
            has_v15_p0 = any(
                item.strip() in {
                    "move-object/from16 v15, p0",
                    "move-object/16 v15, p0",
                    "move-object v15, p0",
                }
                for item in lines[method_start:index]
            )

            if not has_v15_p0:
                abort(
                    "scanPackageForInitLI não copia p0 para v15"
                )

            receiver_register = "v15"

        invocation_registers = ", ".join(
            [receiver_register, *registers]
        )

        lines[index] = (
            f"{indent}invoke-direct "
            f"{{{invocation_registers}}}, "
            f"{APPLY_WRAPPER_CALL}\n"
        )

        repaired += 1

    current = "".join(lines)

    if (
        repaired > 0
        and f".method private {APPLY_WRAPPER_NAME}(" not in current
    ):
        append_method(
            lines,
            f"""
.method private {APPLY_WRAPPER_NAME}(Lcom/android/internal/pm/parsing/pkg/ParsedPackage;ILcom/android/server/pm/pkg/AndroidPackage;Z)V
    .locals 1

    iget-object v0, p0, Lcom/android/server/pm/InstallPackageHelper;->mCustomPlatformSignatures:[Landroid/content/pm/Signature;

    invoke-static {{p1, p2, p3, p4, v0}}, {NEW_APPLY}

    return-void
.end method
""",
        )

    if repaired:
        print(
            "OK: chamadas applyPolicy antigas reparadas: "
            f"{repaired}"
        )
    else:
        print("OK: nenhuma chamada applyPolicy antiga restante")

    return repaired


def find_prepare_package(
    lines: list[str],
) -> tuple[int, int, str]:
    matches = [
        item
        for item in method_ranges(lines)
        if "preparePackage(" in item[2]
        and "Lcom/android/server/pm/InstallRequest;" in item[2]
    ]

    if len(matches) != 1:
        abort(
            "esperava exatamente um preparePackage(InstallRequest); "
            f"encontrei {len(matches)}"
        )

    return matches[0]


def get_signing_entries(
    lines: list[str],
    method_start: int,
    method_end: int,
) -> list[tuple[int, str]]:
    entries: list[tuple[int, str]] = []

    for index in range(method_start, method_end + 1):
        line = lines[index]

        if SET_SIGNING in line:
            entries.append((index, "direct"))

        elif SIGNING_WRAPPER_CALL in line:
            entries.append((index, "wrapper"))

    return entries


def repair_signing_flows(lines: list[str]) -> int:
    method_start, method_end, header = find_prepare_package(lines)

    if re.search(r"\bstatic\b", header):
        abort("preparePackage inesperadamente é estático")

    entries = get_signing_entries(
        lines,
        method_start,
        method_end,
    )

    if len(entries) != 2:
        details = ", ".join(
            f"{kind}@{index + 1}"
            for index, kind in entries
        )

        abort(
            "esperava exatamente dois fluxos de assinatura em "
            "preparePackage; encontrei "
            f"{len(entries)}"
            + (f": {details}" if details else "")
        )

    unprotected: list[int] = []
    directly_protected: list[int] = []
    wrapper_protected: list[int] = []

    for position, (index, kind) in enumerate(entries):
        boundary = (
            entries[position + 1][0]
            if position + 1 < len(entries)
            else method_end
        )

        if kind == "wrapper":
            wrapper_protected.append(index)
            continue

        segment = "".join(
            lines[index + 1:boundary]
        )

        if SET_CUSTOM in segment:
            directly_protected.append(index)
        else:
            unprotected.append(index)

    print(
        "Fluxos encontrados: "
        + ", ".join(
            f"{kind}@{index + 1}"
            for index, kind in entries
        )
    )

    print(
        "Protegidos diretamente: "
        + (
            ", ".join(
                str(index + 1)
                for index in directly_protected
            )
            if directly_protected
            else "nenhum"
        )
    )

    print(
        "Protegidos por wrapper: "
        + (
            ", ".join(
                str(index + 1)
                for index in wrapper_protected
            )
            if wrapper_protected
            else "nenhum"
        )
    )

    print(
        "Ainda sem proteção: "
        + (
            ", ".join(
                str(index + 1)
                for index in unprotected
            )
            if unprotected
            else "nenhum"
        )
    )

    repaired = 0

    for index in unprotected:
        _, registers = parse_invoke_registers(lines[index])

        if len(registers) != 2:
            abort(
                "setSigningDetails deveria usar dois registros "
                f"na linha {index + 1}; encontrou "
                f"{len(registers)}"
            )

        parsed_package, signing_details = registers

        following = next_instruction(
            lines,
            index,
            method_end,
        )

        if following.startswith("move-result"):
            abort(
                "o retorno de setSigningDetails é consumido "
                f"na linha {index + 1}; alteração recusada"
            )

        indent = lines[index][
            :len(lines[index]) - len(lines[index].lstrip())
        ]

        lines[index] = (
            f"{indent}invoke-direct "
            f"{{p0, {parsed_package}, {signing_details}}}, "
            f"{SIGNING_WRAPPER_CALL}\n"
        )

        repaired += 1

    current = "".join(lines)

    if (
        repaired > 0
        and f".method private {SIGNING_WRAPPER_NAME}(" not in current
    ):
        append_method(
            lines,
            f"""
.method private {SIGNING_WRAPPER_NAME}(Lcom/android/internal/pm/parsing/pkg/ParsedPackage;Landroid/content/pm/SigningDetails;)V
    .locals 3

    invoke-interface {{p1, p2}}, {SET_SIGNING}

    iget-object v0, p0, Lcom/android/server/pm/InstallPackageHelper;->mPm:Lcom/android/server/pm/PackageManagerService;

    iget-object v0, v0, Lcom/android/server/pm/PackageManagerService;->mPlatformPackage:Lcom/android/server/pm/pkg/AndroidPackage;

    iget-object v1, p0, Lcom/android/server/pm/InstallPackageHelper;->mCustomPlatformSignatures:[Landroid/content/pm/Signature;

    invoke-virtual {{p2}}, Landroid/content/pm/SigningDetails;->getSignatures()[Landroid/content/pm/Signature;

    move-result-object v2

    invoke-static {{p1, v0, v1, v2}}, {SET_CUSTOM}

    return-void
.end method
""",
        )

    print(
        "OK: fluxos setSigningDetails reparados: "
        f"{repaired}"
    )

    return repaired


def audit_signing_flows(
    lines: list[str],
) -> tuple[bool, str]:
    method_start, method_end, _ = find_prepare_package(lines)

    entries = get_signing_entries(
        lines,
        method_start,
        method_end,
    )

    if len(entries) != 2:
        return (
            False,
            f"preparePackage possui {len(entries)} fluxos, não 2",
        )

    protected = 0

    for position, (index, kind) in enumerate(entries):
        boundary = (
            entries[position + 1][0]
            if position + 1 < len(entries)
            else method_end
        )

        if kind == "wrapper":
            protected += 1
            continue

        if SET_CUSTOM in "".join(
            lines[index + 1:boundary]
        ):
            protected += 1

    if protected != 2:
        return (
            False,
            f"apenas {protected} de 2 fluxos estão protegidos",
        )

    wrapper_calls = sum(
        1
        for _, kind in entries
        if kind == "wrapper"
    )

    if wrapper_calls:
        full_text = "".join(lines)

        if (
            f".method private {SIGNING_WRAPPER_NAME}("
            not in full_text
        ):
            return False, "wrapper de assinatura não existe"

        wrapper_method = [
            item
            for item in method_ranges(lines)
            if SIGNING_WRAPPER_NAME in item[2]
        ]

        if len(wrapper_method) != 1:
            return (
                False,
                "wrapper de assinatura duplicado ou ausente",
            )

        start, end, _ = wrapper_method[0]
        body = "".join(lines[start:end + 1])

        if SET_SIGNING not in body or SET_CUSTOM not in body:
            return (
                False,
                "wrapper não executa setSigningDetails "
                "e setCustomSignatures",
            )

    return True, "dois fluxos de assinatura protegidos"


def audit(root: Path) -> None:
    install = find_one(root, "InstallPackageHelper.smali")
    scan = find_one(root, "ScanPackageUtils.smali")
    pmutils = find_one(
        root,
        "PackageManagerServiceUtils.smali",
    )

    install_lines = install.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    install_text = "".join(install_lines)

    scan_text = scan.read_text(
        encoding="utf-8",
        errors="strict",
    )

    pmutils_text = pmutils.read_text(
        encoding="utf-8",
        errors="strict",
    )

    signing_ok, signing_description = audit_signing_flows(
        install_lines
    )

    apply_calls_outside_wrapper = 0

    for start, end, header in method_ranges(install_lines):
        if APPLY_WRAPPER_NAME in header:
            continue

        body = "".join(
            install_lines[start:end + 1]
        )

        apply_calls_outside_wrapper += body.count(NEW_APPLY)
        apply_calls_outside_wrapper += body.count(
            APPLY_WRAPPER_CALL
        )

    checks = {
        "campo mCustomPlatformSignatures": (
            "mCustomPlatformSignatures:"
            "[Landroid/content/pm/Signature;"
            in install_text
        ),
        "método createSignatures": (
            ".method public static createSignatures("
            "[Ljava/lang/String;)"
            "[Landroid/content/pm/Signature;"
            in install_text
        ),
        "placeholder de certificado presente": (
            "CONFIG_CUSTOM_PLATFORM_SIGNATURE"
            in install_text
        ),
        "nenhuma chamada applyPolicy antiga": (
            OLD_APPLY not in install_text
        ),
        "dois fluxos applyPolicy protegidos": (
            apply_calls_outside_wrapper == 2
        ),
        signing_description: signing_ok,
        "compareSignaturesActual": (
            ".method public static "
            "compareSignaturesActual("
            in pmutils_text
        ),
        "applyPolicy recebe assinaturas customizadas": (
            ".method public static applyPolicy("
            "Lcom/android/internal/pm/parsing/pkg/ParsedPackage;"
            "ILcom/android/server/pm/pkg/AndroidPackage;"
            "Z[Landroid/content/pm/Signature;)V"
            in scan_text
        ),
        "método setCustomSignatures": (
            ".method public static setCustomSignatures("
            in scan_text
        ),
        "método signedWithCustomSignatures": (
            ".method public static "
            "signedWithCustomSignatures("
            in scan_text
        ),
    }

    failures: list[str] = []

    for description, passed in checks.items():
        print(
            f"{'OK' if passed else 'FALHOU'}: "
            f"{description}"
        )

        if not passed:
            failures.append(description)

    install_reject = Path(str(install) + ".rej")

    unexpected_rejects = [
        reject
        for reject in root.rglob("*.rej")
        if reject != install_reject
    ]

    if unexpected_rejects:
        for reject in unexpected_rejects:
            print(f"FALHOU: reject inesperado: {reject}")

        failures.append("existem rejects inesperados")

    if failures:
        abort(
            "spoof de assinatura incompleto: "
            + "; ".join(failures)
        )

    if install_reject.exists():
        install_reject.unlink()
        print("OK: InstallPackageHelper.smali.rej removido")

    print()
    print("OK: spoof de assinatura completamente aplicado")


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: repair_signature_oneui9.py "
            "<services.jar decodificado>"
        )

    root = Path(sys.argv[1])

    if not root.is_dir():
        abort(f"diretório inexistente: {root}")

    install = find_one(root, "InstallPackageHelper.smali")

    lines = install.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    repair_apply_policy(lines)
    repair_signing_flows(lines)

    install.write_text(
        "".join(lines),
        encoding="utf-8",
    )

    audit(root)


if __name__ == "__main__":
    main()
