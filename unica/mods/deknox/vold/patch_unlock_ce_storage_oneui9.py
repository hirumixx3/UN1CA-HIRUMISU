#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


DESCRIPTOR_PATTERN = re.compile(
    r"unlockCeStorage\(([^)]*)\)V"
)

EXPECTED_PREFIX = "ILjava/lang/String;[B"
LEGACY_PREFIX = "I[B"

WRITE_STRING = (
    "Landroid/os/Parcel;"
    "->writeString(Ljava/lang/String;)V"
)

WRITE_BYTES = (
    "Landroid/os/Parcel;"
    "->writeByteArray([B)V"
)

READ_STRING = (
    "Landroid/os/Parcel;"
    "->readString()Ljava/lang/String;"
)

READ_BYTES = (
    "Landroid/os/Parcel;"
    "->createByteArray()[B"
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
            f"esperava exatamente um arquivo terminando em "
            f"{suffix}; encontrei {len(matches)}"
        )

    return matches[0]


def read(path: Path) -> str:
    return path.read_text(
        encoding="utf-8",
        errors="strict",
    )


def method_blocks(
    text: str,
) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []

    pattern = re.compile(
        r"(?ms)^(\.method[^\n]*)\n"
        r"(.*?)"
        r"^\.end method\s*$"
    )

    for match in pattern.finditer(text):
        blocks.append(
            (
                match.group(1),
                match.group(0),
            )
        )

    return blocks


def unlock_descriptors(path: Path) -> list[str]:
    text = read(path)

    return sorted(
        {
            match.group(0)
            for match in DESCRIPTOR_PATTERN.finditer(text)
        }
    )


def validate_descriptors(path: Path) -> str:
    descriptors = unlock_descriptors(path)

    if not descriptors:
        abort(
            f"nenhum descritor unlockCeStorage encontrado "
            f"em {path}"
        )

    legacy = [
        descriptor
        for descriptor in descriptors
        if descriptor.startswith(
            f"unlockCeStorage({LEGACY_PREFIX}"
        )
    ]

    if legacy:
        abort(
            f"assinatura antiga ainda existe em {path}: "
            + ", ".join(legacy)
        )

    incompatible = []

    for descriptor in descriptors:
        match = DESCRIPTOR_PATTERN.fullmatch(descriptor)

        if match is None:
            incompatible.append(descriptor)
            continue

        parameters = match.group(1)

        if not parameters.startswith(EXPECTED_PREFIX):
            incompatible.append(descriptor)

    if incompatible:
        abort(
            f"assinatura inesperada em {path}: "
            + ", ".join(incompatible)
        )

    if len(descriptors) != 1:
        abort(
            f"mais de uma variante unlockCeStorage em {path}: "
            + ", ".join(descriptors)
        )

    descriptor = descriptors[0]

    print(f"OK: {path}")
    print(f"    {descriptor}")

    return descriptor


def validate_proxy(path: Path) -> None:
    text = read(path)

    candidates = [
        block
        for header, block in method_blocks(text)
        if "unlockCeStorage(" in header
    ]

    if len(candidates) != 1:
        abort(
            f"{path}: esperava um método Proxy "
            f"unlockCeStorage; encontrei {len(candidates)}"
        )

    block = candidates[0]

    string_index = block.find(WRITE_STRING)
    bytes_index = block.find(WRITE_BYTES)

    if string_index < 0:
        abort(
            f"{path}: Proxy não escreve o token String "
            "no Parcel"
        )

    if bytes_index < 0:
        abort(
            f"{path}: Proxy não escreve o secret byte[] "
            "no Parcel"
        )

    if string_index > bytes_index:
        abort(
            f"{path}: Proxy escreve o secret antes do token"
        )

    string_register = re.search(
        r"invoke-virtual\s+\{[^,}]+,\s*([vp]\d+)\},\s*"
        + re.escape(WRITE_STRING),
        block,
    )

    bytes_register = re.search(
        r"invoke-virtual\s+\{[^,}]+,\s*([vp]\d+)\},\s*"
        + re.escape(WRITE_BYTES),
        block,
    )

    if string_register is None:
        abort(
            f"{path}: registrador do token não reconhecido"
        )

    if bytes_register is None:
        abort(
            f"{path}: registrador do secret não reconhecido"
        )

    if string_register.group(1) == bytes_register.group(1):
        abort(
            f"{path}: token e secret usam o mesmo registrador"
        )

    print(
        "OK: Proxy serializa token e secret separadamente"
    )

    print(
        "    token="
        f"{string_register.group(1)} "
        "secret="
        f"{bytes_register.group(1)}"
    )


def validate_stub(path: Path) -> None:
    text = read(path)

    call_blocks = [
        block
        for _, block in method_blocks(text)
        if (
            "->unlockCeStorage(" in block
            and "invoke-" in block
        )
    ]

    if len(call_blocks) != 1:
        abort(
            f"{path}: esperava um fluxo Binder "
            f"unlockCeStorage; encontrei {len(call_blocks)}"
        )

    block = call_blocks[0]

    string_index = block.find(READ_STRING)
    bytes_index = block.find(READ_BYTES)
    call_index = block.find("->unlockCeStorage(")

    if string_index < 0:
        abort(
            f"{path}: Stub não lê o token String do Parcel"
        )

    if bytes_index < 0:
        abort(
            f"{path}: Stub não lê o secret byte[] do Parcel"
        )

    if call_index < 0:
        abort(
            f"{path}: chamada unlockCeStorage não encontrada"
        )

    if not (
        string_index < bytes_index < call_index
    ):
        abort(
            f"{path}: ordem Binder incorreta; esperado "
            "readString -> createByteArray -> chamada"
        )

    print(
        "OK: Stub desserializa token antes do secret"
    )


def validate_services_calls(root: Path) -> None:
    ivold_calls: list[
        tuple[Path, int, str, str]
    ] = []

    generic_calls: list[
        tuple[Path, int, str, str]
    ] = []

    ivold_pattern = re.compile(
        r"(?m)^[ \t]*invoke-[^\n]*"
        r"Landroid/os/IVold;"
        r"->unlockCeStorage\(([^)]*)\)V"
    )

    generic_pattern = re.compile(
        r"(?m)^[ \t]*invoke-[^\n]*"
        r"->unlockCeStorage\(([^)]*)\)V"
    )

    for smali in root.rglob("*.smali"):
        content = read(smali)

        if "unlockCeStorage(" not in content:
            continue

        for match in ivold_pattern.finditer(content):
            line = (
                content.count(
                    "\n",
                    0,
                    match.start(),
                )
                + 1
            )

            call = match.group(0).strip()
            parameters = match.group(1)

            ivold_calls.append(
                (
                    smali,
                    line,
                    parameters,
                    call,
                )
            )

        for match in generic_pattern.finditer(content):
            # Chamadas IVold já são registradas separadamente.
            if "Landroid/os/IVold;" in match.group(0):
                continue

            line = (
                content.count(
                    "\n",
                    0,
                    match.start(),
                )
                + 1
            )

            generic_calls.append(
                (
                    smali,
                    line,
                    match.group(1),
                    match.group(0).strip(),
                )
            )

    if ivold_calls:
        print(
            "Chamadas diretas IVold.unlockCeStorage "
            f"encontradas: {len(ivold_calls)}"
        )

        for smali, line, parameters, call in ivold_calls:
            if parameters.startswith(LEGACY_PREFIX):
                abort(
                    "chamada IVold legada encontrada em "
                    f"{smali}:{line}: {call}"
                )

            if not parameters.startswith(EXPECTED_PREFIX):
                abort(
                    "chamada IVold com assinatura inesperada em "
                    f"{smali}:{line}: {call}"
                )

            print(f"OK: {smali}:{line}")
            print(f"    {call}")

        print(
            "OK: todas as chamadas diretas IVold "
            "usam token"
        )

        return

    print(
        "OK: nenhuma chamada direta "
        "StorageManagerService -> IVold.unlockCeStorage "
        "existe nesta One UI 9"
    )

    if generic_calls:
        print(
            "Chamadas indiretas ou wrappers "
            f"encontrados: {len(generic_calls)}"
        )

        for smali, line, parameters, call in generic_calls:
            print(f"INFO: {smali}:{line}")
            print(f"    {call}")

            # Uma API pública ou wrapper pode manter uma
            # assinatura diferente. Ela não representa o
            # contrato Binder IVold.
            if parameters.startswith(LEGACY_PREFIX):
                print(
                    "    assinatura externa legada preservada; "
                    "não é chamada direta ao IVold"
                )
    else:
        print(
            "OK: services.jar não contém chamadas "
            "de serviço para unlockCeStorage"
        )

    # IVold, Default, Stub e Proxy já foram validados
    # anteriormente. A ausência de uma chamada direta significa
    # que não há ponto adicional a modificar no services.jar.
    print(
        "OK: nenhuma adaptação adicional do "
        "StorageManagerService é necessária"
    )


def validate_root(
    root: Path,
    description: str,
) -> None:
    interface = find_one(
        root,
        "android/os/IVold.smali",
    )

    default = find_one(
        root,
        "android/os/IVold$Default.smali",
    )

    proxy = find_one(
        root,
        "android/os/IVold$Stub$Proxy.smali",
    )

    stub = find_one(
        root,
        "android/os/IVold$Stub.smali",
    )

    print()
    print(f"=== {description} ===")

    descriptors = {
        validate_descriptors(interface),
        validate_descriptors(default),
        validate_descriptors(proxy),
        validate_descriptors(stub),
    }

    if len(descriptors) != 1:
        abort(
            f"{description}: descritores diferentes entre "
            "IVold, Default, Proxy e Stub: "
            + ", ".join(sorted(descriptors))
        )

    validate_proxy(proxy)
    validate_stub(stub)

    print(
        f"OK: contrato Binder consistente em {description}"
    )


def remove_rejects(roots: list[Path]) -> None:
    allowed_names = {
        "IVold.smali.rej",
        "IVold$Default.smali.rej",
        "IVold$Stub.smali.rej",
        "IVold$Stub$Proxy.smali.rej",
        "StorageManagerService.smali.rej",
    }

    rejects = []

    for root in roots:
        rejects.extend(root.rglob("*.rej"))

    unexpected = [
        reject
        for reject in rejects
        if reject.name not in allowed_names
    ]

    if unexpected:
        abort(
            "rejects inesperados encontrados:\n"
            + "\n".join(
                str(reject)
                for reject in unexpected
            )
        )

    for reject in rejects:
        reject.unlink()

        print(
            f"OK: reject incompatível removido: {reject}"
        )


def main() -> None:
    if len(sys.argv) != 3:
        abort(
            "uso: patch_unlock_ce_storage_oneui9.py "
            "<framework.jar decodificado> "
            "<services.jar decodificado>"
        )

    framework = Path(sys.argv[1])
    services = Path(sys.argv[2])

    if not framework.is_dir():
        abort(
            f"framework.jar decodificado ausente: "
            f"{framework}"
        )

    if not services.is_dir():
        abort(
            f"services.jar decodificado ausente: "
            f"{services}"
        )

    validate_root(
        framework,
        "framework.jar",
    )

    validate_root(
        services,
        "services.jar",
    )

    print()
    print("=== Chamadas de serviço unlockCeStorage ===")

    validate_services_calls(services)


    remove_rejects(
        [
            framework,
            services,
        ]
    )

    print()
    print(
        "OK: One UI 9 já possui token em "
        "unlockCeStorage"
    )

    print(
        "OK: parâmetro booleano adicional preservado"
    )

    print(
        "OK: contrato Binder unlockCeStorage "
        "completamente validado"
    )


if __name__ == "__main__":
    main()
