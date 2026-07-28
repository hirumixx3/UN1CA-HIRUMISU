#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


POLICY_CLASS = (
    "Lcom/samsung/android/server/pm/install/"
    "PackageBlockListPolicy;"
)

OLD_FIELD = (
    POLICY_CLASS
    + "->sLduBlocklist:Ljava/util/HashSet;"
)

NEW_FIELD = (
    POLICY_CLASS
    + "->sBlocklist:Ljava/util/HashSet;"
)

RDU_FIELD = (
    POLICY_CLASS
    + "->sIsRduDevice:"
    "Ljava/util/concurrent/atomic/AtomicBoolean;"
)

OLD_XML = "/system/etc/ldu_blocklist.xml"
NEW_XML = "/system/etc/unica_blocklist.xml"


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


def patch_install_helper(path: Path) -> tuple[int, int, int]:
    lines = path.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    rdu_indexes = [
        index
        for index, line in enumerate(lines)
        if RDU_FIELD in line
    ]

    rdu_replacements = 0

    # Processar de baixo para cima preserva os índices.
    for start in reversed(rdu_indexes):
        source_line = lines[start]

        source_match = re.match(
            r"^(?P<indent>[ \t]*)"
            r"sget-object\s+"
            r"(?P<register>[vp]\d+),\s*"
            + re.escape(RDU_FIELD)
            + r"\s*$",
            source_line.rstrip("\n"),
        )

        if not source_match:
            context = "".join(
                lines[max(0, start - 4):start + 12]
            )

            abort(
                "referência sIsRduDevice não reconhecida "
                f"na linha {start + 1}:\n{context}"
            )

        indent = source_match.group("indent")
        object_register = source_match.group("register")

        get_index = None

        for index in range(
            start + 1,
            min(len(lines), start + 30),
        ):
            instruction = lines[index].strip()

            if (
                not instruction
                or instruction.startswith("#")
                or instruction.startswith(".line")
                or instruction.startswith(".local")
            ):
                continue

            if instruction.startswith(":"):
                abort(
                    "label encontrada entre sIsRduDevice e "
                    f"AtomicBoolean.get() na linha {index + 1}"
                )

            if (
                "Ljava/util/concurrent/atomic/AtomicBoolean;"
                "->get()Z"
                in instruction
            ):
                register_match = re.search(
                    r"\{([^}]*)\}",
                    instruction,
                )

                if not register_match:
                    abort(
                        "registradores de AtomicBoolean.get() "
                        "não reconhecidos"
                    )

                invoke_registers = register_match.group(1)

                if object_register not in invoke_registers:
                    abort(
                        "AtomicBoolean.get() não usa o registro "
                        f"{object_register}"
                    )

                get_index = index
                break

        if get_index is None:
            context = "".join(
                lines[start:min(len(lines), start + 30)]
            )

            abort(
                "AtomicBoolean.get() relacionado a "
                f"sIsRduDevice não encontrado:\n{context}"
            )

        next_index = None
        next_instruction_text = ""

        for index in range(
            get_index + 1,
            min(len(lines), get_index + 15),
        ):
            instruction = lines[index].strip()

            if (
                not instruction
                or instruction.startswith("#")
                or instruction.startswith(".line")
                or instruction.startswith(".local")
            ):
                continue

            next_index = index
            next_instruction_text = instruction
            break

        if next_index is None:
            abort(
                "nenhuma instrução encontrada depois de "
                "AtomicBoolean.get()"
            )

        move_match = re.fullmatch(
            r"move-result(?:/from16)?\s+([vp]\d+)",
            next_instruction_text,
        )

        if move_match:
            # Variante antiga:
            #
            # sget-object vX, sIsRduDevice
            # invoke-virtual {vX}, AtomicBoolean->get()Z
            # move-result vY
            #
            # Torna o resultado verdadeiro.
            result_register = move_match.group(1)

            lines[start] = ""
            lines[get_index] = ""
            lines[next_index] = (
                f"{indent}const/4 {result_register}, 0x1\n"
            )

            print(
                "OK: resultado de sIsRduDevice.get() "
                f"forçado para true na linha {start + 1}"
            )
        else:
            # Variante One UI 9 observada:
            #
            # sget-object vX, sIsRduDevice
            # invoke-virtual {vX}, AtomicBoolean->get()Z
            # sget-object vX, sLduBlocklist
            #
            # O resultado do get() é ignorado e vX é imediatamente
            # sobrescrito. Basta remover as duas instruções inúteis.
            lines[start] = ""
            lines[get_index] = ""

            print(
                "OK: leitura sem uso de sIsRduDevice removida; "
                "próxima instrução: "
                + next_instruction_text
            )

        rdu_replacements += 1

    text = "".join(lines)

    if RDU_FIELD in text:
        abort(
            "alguma referência sIsRduDevice permaneceu "
            "em InstallPackageHelper"
        )

    old_field_count = text.count(OLD_FIELD)
    old_xml_count = text.count(OLD_XML)

    text = text.replace(
        OLD_FIELD,
        NEW_FIELD,
    )

    text = text.replace(
        OLD_XML,
        NEW_XML,
    )

    failures = []

    if OLD_FIELD in text:
        failures.append("sLduBlocklist permaneceu")

    if OLD_XML in text:
        failures.append("ldu_blocklist.xml permaneceu")

    if NEW_FIELD not in text:
        failures.append("sBlocklist não foi encontrado")

    if NEW_XML not in text:
        failures.append("unica_blocklist.xml não foi encontrado")

    if failures:
        abort(
            "InstallPackageHelper incompleto: "
            + "; ".join(failures)
        )

    temporary = path.with_name(
        path.name + ".unica-blocklist.tmp"
    )

    temporary.write_text(
        text,
        encoding="utf-8",
    )

    temporary.replace(path)

    return (
        rdu_replacements,
        old_field_count,
        old_xml_count,
    )


def patch_policy_class(path: Path) -> int:
    text = path.read_text(
        encoding="utf-8",
        errors="strict",
    )

    original = text

    text = text.replace(
        ".field public static sLduBlocklist:"
        "Ljava/util/HashSet;",
        ".field public static sBlocklist:"
        "Ljava/util/HashSet;",
    )

    text = re.sub(
        r"(?m)^\.field public static final "
        r"sIsRduDevice:"
        r"Ljava/util/concurrent/atomic/AtomicBoolean;"
        r"\n(?:\n)?",
        "",
        text,
    )

    constructor_pattern = re.compile(
        r"(?ms)"
        r"^\.method static constructor <clinit>\(\)V\n"
        r".*?"
        r"^\.end method\n?"
    )

    removed_constructors = 0

    for match in list(constructor_pattern.finditer(text)):
        body = match.group(0)

        if (
            "sIsRduDevice" in body
            and "AtomicBoolean" in body
        ):
            text = (
                text[:match.start()]
                + text[match.end():]
            )

            removed_constructors += 1
            break

    if (
        ".field public static sBlocklist:"
        "Ljava/util/HashSet;"
        not in text
    ):
        abort("campo sBlocklist ausente em PackageBlockListPolicy")

    if "sIsRduDevice" in text:
        abort("sIsRduDevice permaneceu em PackageBlockListPolicy")

    if "sLduBlocklist" in text:
        abort("sLduBlocklist permaneceu em PackageBlockListPolicy")

    if text != original:
        temporary = path.with_name(
            path.name + ".unica-blocklist.tmp"
        )

        temporary.write_text(
            text,
            encoding="utf-8",
        )

        temporary.replace(path)

    return removed_constructors


def validate_lifecycle(path: Path) -> None:
    text = path.read_text(
        encoding="utf-8",
        errors="strict",
    )

    forbidden = {
        "sIsRduDevice": "observador RDU antigo",
        "sLduBlocklist": "campo LDU antigo",
        "PackageBlockListPolicy$1;-><init>": (
            "criação do observador antigo"
        ),
    }

    failures = [
        description
        for token, description in forbidden.items()
        if token in text
    ]

    if failures:
        abort(
            "PmLifecycleImpl ainda contém: "
            + "; ".join(failures)
        )


def validate_signature_spoof(install: Path) -> None:
    text = install.read_text(
        encoding="utf-8",
        errors="strict",
    )

    required = [
        "mCustomPlatformSignatures:"
        "[Landroid/content/pm/Signature;",
        "applyPolicyWithCustomSignatures",
        "setSigningDetailsWithCustomSignatures",
    ]

    missing = [
        token
        for token in required
        if token not in text
    ]

    if missing:
        abort(
            "a validação do spoof de assinatura falhou: "
            + ", ".join(missing)
        )


def validate_no_old_references(root: Path) -> None:
    failures = []

    for path in root.rglob("*.smali"):
        text = path.read_text(
            encoding="utf-8",
            errors="replace",
        )

        found = [
            token
            for token in (
                "sLduBlocklist",
                "sIsRduDevice",
                OLD_XML,
            )
            if token in text
        ]

        if found:
            failures.append(
                f"{path}: {', '.join(found)}"
            )

    if failures:
        abort(
            "referências antigas restantes:\n"
            + "\n".join(failures)
        )


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: repair_blocklist_oneui9.py "
            "<services.jar decodificado>"
        )

    root = Path(sys.argv[1])

    if not root.is_dir():
        abort(f"diretório inexistente: {root}")

    install = find_one(
        root,
        "InstallPackageHelper.smali",
    )

    policy = find_one(
        root,
        "PackageBlockListPolicy.smali",
    )

    lifecycle = find_one(
        root,
        "PmLifecycleImpl.smali",
    )

    (
        rdu_replacements,
        field_replacements,
        xml_replacements,
    ) = patch_install_helper(install)

    removed_constructors = patch_policy_class(policy)

    validate_lifecycle(lifecycle)

    observer_matches = list(
        root.rglob("PackageBlockListPolicy$1.smali")
    )

    if len(observer_matches) > 1:
        abort(
            "mais de uma classe "
            "PackageBlockListPolicy$1.smali encontrada"
        )

    observer_removed = 0

    if observer_matches:
        observer_matches[0].unlink()
        observer_removed = 1

    reject = Path(str(install) + ".rej")

    if reject.exists():
        reject.unlink()
        print("OK: reject do InstallPackageHelper removido")

    validate_signature_spoof(install)
    validate_no_old_references(root)

    final = install.read_text(
        encoding="utf-8",
        errors="strict",
    )

    if final.count(NEW_FIELD) < 3:
        abort(
            "esperava pelo menos três referências "
            "ao novo campo sBlocklist"
        )

    if final.count(NEW_XML) < 1:
        abort(
            "caminho unica_blocklist.xml ausente"
        )

    print(
        "OK: verificações RDU substituídas: "
        f"{rdu_replacements}"
    )

    print(
        "OK: referências sLduBlocklist substituídas: "
        f"{field_replacements}"
    )

    print(
        "OK: caminhos ldu_blocklist substituídos: "
        f"{xml_replacements}"
    )

    print(
        "OK: construtores RDU removidos: "
        f"{removed_constructors}"
    )

    print(
        "OK: observadores PackageBlockListPolicy$1 "
        f"removidos: {observer_removed}"
    )

    print("OK: spoof de assinatura continua presente")
    print("OK: PackageBlockListPolicy customizada completamente aplicada")


if __name__ == "__main__":
    main()
