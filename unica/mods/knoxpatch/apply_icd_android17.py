#!/usr/bin/env python3

from pathlib import Path
import hashlib
import re
import sys


def find_services_dir(root: Path) -> Path:
    candidates = []

    for candidate in root.glob(
        "out/target/*/apktool/system/framework/services.jar"
    ):
        if not candidate.is_dir():
            continue

        attest = list(
            candidate.rglob(
                "com/samsung/android/security/"
                "keystore/AttestationUtils.smali"
            )
        )

        if attest:
            candidates.append(candidate)

    if not candidates:
        raise SystemExit(
            "ERRO: services.jar decompilado não encontrado. "
            "O helper precisa executar depois de um SMALI_PATCH "
            "em services.jar."
        )

    candidates.sort(
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )

    return candidates[0]


def remove_reflection_blocks(text: str, source: Path) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    removed = 0

    while True:
        marker = next(
            (
                index
                for index, line in enumerate(lines)
                if '"mVerifiableIntegrity"' in line
            ),
            None,
        )

        if marker is None:
            break

        start = None
        end = None

        for index in range(marker, max(-1, marker - 15), -1):
            line = lines[index]

            if (
                "const-class" in line
                and "AttestParameterSpec$Builder;" in line
            ):
                start = index
                break

        for index in range(
            marker,
            min(len(lines), marker + 30),
        ):
            line = lines[index]

            if (
                "Ljava/lang/reflect/Field;->set("
                "Ljava/lang/Object;Ljava/lang/Object;)V"
                in line
            ):
                end = index
                break

        if start is None or end is None:
            raise SystemExit(
                "ERRO: referência reflexiva a "
                f"mVerifiableIntegrity não reconhecida em {source} "
                f"próximo da linha {marker + 1}."
            )

        while start > 0 and lines[start - 1].strip() == "":
            start -= 1

        while end + 1 < len(lines) and lines[end + 1].strip() == "":
            end += 1

        del lines[start:end + 1]
        removed += 1

    return "".join(lines), removed


def remove_field_operations(
    text: str,
    source: Path,
) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    delete = set()
    removed = 0

    descriptor = "->mVerifiableIntegrity:Z"

    for index, line in enumerate(lines):
        stripped = line.strip()

        if (
            stripped.startswith(".field ")
            and "mVerifiableIntegrity:Z" in stripped
        ):
            delete.add(index)
            removed += 1
            continue

        if descriptor not in line:
            continue

        iget = re.search(
            r"\biget-boolean\s+([vp]\d+)\s*,",
            line,
        )

        delete.add(index)
        removed += 1

        if not iget:
            continue

        register = iget.group(1)

        # AttestationUtils usa:
        #
        # iget-boolean v0, ..., ->mVerifiableIntegrity:Z
        # const-string v2, "AttestationUtils"
        # if-eqz v0, :cond_X
        # const v0, 0x700008fe
        #
        # Ao remover o teste, o parâmetro 0x700008fe passa a ser
        # sempre adicionado, que é a semântica original do patch.
        found_key_parameter = False

        for scan in range(
            index + 1,
            min(len(lines), index + 16),
        ):
            current = lines[scan].strip()

            if "0x700008fe" in current:
                found_key_parameter = True
                break

            if re.match(
                rf"if-(?:eqz|nez)\s+{re.escape(register)}\s*,",
                current,
            ):
                delete.add(scan)
                removed += 1
                continue

        # Em outras classes, como Builder, o iget não controla
        # diretamente o parâmetro 0x700008fe. Nesses casos somente
        # o iget e o iput correspondente são removidos.
        _ = found_key_parameter

    if not delete:
        return text, 0

    output = [
        line
        for index, line in enumerate(lines)
        if index not in delete
    ]

    result = "".join(output)

    # Remove somente excesso de linhas vazias criado pela exclusão.
    result = re.sub(r"\n{4,}", "\n\n\n", result)

    return result, removed


def process_file(path: Path) -> tuple[bool, int]:
    original = path.read_text(
        encoding="utf-8",
        errors="strict",
    )

    modified, reflection_count = remove_reflection_blocks(
        original,
        path,
    )

    modified, operation_count = remove_field_operations(
        modified,
        path,
    )

    if modified == original:
        return False, 0

    path.write_text(
        modified,
        encoding="utf-8",
    )

    return True, reflection_count + operation_count


def main() -> None:
    root = (
        Path(sys.argv[1]).resolve()
        if len(sys.argv) > 1
        else Path("/root/UN1CA-HIRUMISU")
    )

    services = find_services_dir(root)

    print(f"ICD Android 17: services.jar = {services}")

    changed_files = []
    total_changes = 0

    for smali in services.rglob("*.smali"):
        text = smali.read_text(
            encoding="utf-8",
            errors="strict",
        )

        if "mVerifiableIntegrity" not in text:
            continue

        changed, changes = process_file(smali)

        if changed:
            changed_files.append(smali)
            total_changes += changes

    remaining = []

    for smali in services.rglob("*.smali"):
        text = smali.read_text(
            encoding="utf-8",
            errors="strict",
        )

        if "mVerifiableIntegrity" in text:
            for number, line in enumerate(
                text.splitlines(),
                start=1,
            ):
                if "mVerifiableIntegrity" in line:
                    remaining.append(
                        f"{smali.relative_to(services)}:"
                        f"{number}: {line.strip()}"
                    )

    if remaining:
        print(
            "ERRO: referências residuais a "
            "mVerifiableIntegrity:",
            file=sys.stderr,
        )

        for item in remaining:
            print(f"  {item}", file=sys.stderr)

        raise SystemExit(2)

    attest_matches = list(
        services.rglob(
            "com/samsung/android/security/"
            "keystore/AttestationUtils.smali"
        )
    )

    if len(attest_matches) != 1:
        raise SystemExit(
            "ERRO: esperado exatamente um "
            "AttestationUtils.smali; encontrados "
            f"{len(attest_matches)}."
        )

    attest_text = attest_matches[0].read_text(
        encoding="utf-8",
        errors="strict",
    )

    if "0x700008fe" not in attest_text:
        raise SystemExit(
            "ERRO: parâmetro de integridade 0x700008fe "
            "não foi localizado em AttestationUtils."
        )

    print()
    print("Arquivos adaptados:")

    if not changed_files:
        print("  Nenhum: adaptação já estava aplicada.")
    else:
        for path in changed_files:
            digest = hashlib.sha256(
                path.read_bytes()
            ).hexdigest()

            print(
                f"  {path.relative_to(services)}"
                f"\n    SHA-256: {digest}"
            )

    print()
    print(f"Alterações semânticas: {total_changes}")
    print("Referências residuais: 0")
    print("Parâmetro 0x700008fe: presente")
    print("ICD Android 17 aplicado com sucesso.")


if __name__ == "__main__":
    main()
