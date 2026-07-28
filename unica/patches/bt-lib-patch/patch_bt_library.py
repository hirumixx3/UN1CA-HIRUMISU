#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import os
import shutil
import sys
import tempfile
from pathlib import Path


PATCHES = [
    # Upstream BluetoothLibraryPatcher: Android 16.
    (
        "Samsung Android 16/17 layout",
        "00122a0140395f01086b00020054",
        "00122a0140395f01086bde030014",
    ),

    # Upstream UN1CA fifteen / Android 15.
    (
        "Samsung Android 15 layout",
        "480500352800805228",
        "530100142800805228",
    ),

    # Assinaturas anteriormente usadas pela UN1CA-HIRUMISU.
    (
        "HIRUMISU layout 1",
        "2897773948050037",
        "289777392a000014",
    ),
    (
        "HIRUMISU layout 2",
        "2897663948050037",
        "289766392a000014",
    ),
    (
        "HIRUMISU layout 3",
        "f6713948050037330080",
        "f671392a000014330080",
    ),
    (
        "HIRUMISU layout 4",
        "f6733948050037330080",
        "f673392a000014330080",
    ),
    (
        "HIRUMISU layout 5",
        "76743948050037330080",
        "7674392a000014330080",
    ),
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Uso: {sys.argv[0]} libbluetooth_jni.so", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])

    if not path.is_file():
        print(f"ERRO: biblioteca não encontrada: {path}", file=sys.stderr)
        return 1

    original = path.read_bytes()

    if not original.startswith(b"\x7fELF"):
        print(f"ERRO: não é um ELF válido: {path}", file=sys.stderr)
        return 1

    print(f"Biblioteca: {path}")
    print(f"Tamanho: {len(original)} bytes")
    print(f"SHA-256 original: {sha256(original)}")

    # Evita aplicar duas vezes.
    for name, before_hex, after_hex in PATCHES:
        after = bytes.fromhex(after_hex)
        count = original.count(after)

        if count == 1:
            print(f"OK: patch já aplicado: {name}")
            return 0

        if count > 1:
            print(
                f"ERRO: sequência pós-patch duplicada ({count}): {name}",
                file=sys.stderr,
            )
            return 1

    candidates: list[tuple[str, bytes, bytes, int]] = []

    for name, before_hex, after_hex in PATCHES:
        before = bytes.fromhex(before_hex)
        after = bytes.fromhex(after_hex)
        count = original.count(before)

        if count:
            candidates.append((name, before, after, count))

    if not candidates:
        print(
            "ERRO: nenhuma assinatura segura conhecida foi encontrada.",
            file=sys.stderr,
        )
        print(
            "A biblioteca foi preservada sem alterações.",
            file=sys.stderr,
        )

        lowered = original.lower()
        for needle in (b"vault", b"keeper", b"security.wsm", b"wsm"):
            if needle in lowered:
                print(
                    f"INFO: string encontrada no ELF: "
                    f"{needle.decode(errors='replace')}",
                    file=sys.stderr,
                )

        return 1

    if len(candidates) != 1:
        print(
            "ERRO: mais de uma assinatura pré-patch foi encontrada:",
            file=sys.stderr,
        )

        for name, _, _, count in candidates:
            print(f"  {name}: {count} ocorrência(s)", file=sys.stderr)

        return 1

    name, before, after, count = candidates[0]

    if count != 1:
        print(
            f"ERRO: assinatura {name} apareceu {count} vezes; "
            "não é seguro aplicar automaticamente.",
            file=sys.stderr,
        )
        return 1

    if len(before) != len(after):
        print(
            f"ERRO interno: tamanhos diferentes em {name}",
            file=sys.stderr,
        )
        return 1

    offset = original.find(before)
    patched = original[:offset] + after + original[offset + len(before):]

    if len(patched) != len(original):
        print("ERRO: tamanho do ELF mudou", file=sys.stderr)
        return 1

    if patched.count(before) != 0:
        print("ERRO: assinatura original permaneceu", file=sys.stderr)
        return 1

    if patched.count(after) != 1:
        print("ERRO: validação da assinatura nova falhou", file=sys.stderr)
        return 1

    backup = Path("/tmp/unica-libbluetooth_jni.so.bak-unpatched")

    if not backup.exists():
        shutil.copy2(path, backup)
        print(f"Backup original: {backup}")

    fd, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".",
        dir=str(path.parent),
    )

    try:
        with os.fdopen(fd, "wb") as temporary:
            temporary.write(patched)
            temporary.flush()
            os.fsync(temporary.fileno())

        shutil.copystat(path, temporary_name)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    final = path.read_bytes()

    if not final.startswith(b"\x7fELF"):
        shutil.copy2(backup, path)
        print("ERRO: ELF inválido; backup restaurado", file=sys.stderr)
        return 1

    print(f"OK: patch aplicado: {name}")
    print(f"Offset: 0x{offset:x}")
    print(f"Antes: {before.hex()}")
    print(f"Depois: {after.hex()}")
    print(f"SHA-256 final: {sha256(final)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
