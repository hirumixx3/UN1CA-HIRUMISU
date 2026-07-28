#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path


CLASS_SUFFIX = (
    "com/samsung/android/settings/security/"
    "PowerOffLockPreferenceController.smali"
)

COUNTRY_CALL = (
    "Landroid/os/SemSystemProperties;"
    "->getCountryIso()Ljava/lang/String;"
)


def abort(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def main() -> None:
    if len(sys.argv) != 3:
        abort(
            "uso: patch_poweroff_lock_oneui9.py "
            "<SecSettings decodificado> <patch original>"
        )

    decoded = Path(sys.argv[1])
    template = Path(sys.argv[2])

    if not decoded.is_dir():
        abort(f"SecSettings decodificado não encontrado: {decoded}")

    if not template.is_file():
        abort(f"patch original não encontrado: {template}")

    matches = [
        path
        for path in decoded.rglob(
            "PowerOffLockPreferenceController.smali"
        )
        if path.as_posix().endswith(CLASS_SUFFIX)
    ]

    if len(matches) != 1:
        abort(
            "esperava exatamente uma "
            "PowerOffLockPreferenceController.smali; "
            f"encontrei {len(matches)}"
        )

    smali = matches[0]
    relative = smali.relative_to(decoded).as_posix()

    original_smali = smali.read_text(
        encoding="utf-8",
        errors="strict",
    )

    print(f"Classe detectada: {relative}")

    # Permite executar novamente no mesmo workdir.
    if COUNTRY_CALL not in original_smali:
        if (
            'const/4 p0, 0x0' in original_smali
            and 'const/4 p0, 0x3' in original_smali
        ):
            print("OK: Power Off Lock já está corrigido")
            return

        abort(
            "getCountryIso() não existe, mas a estrutura "
            "esperada do patch também não foi encontrada"
        )

    patch_text = template.read_text(
        encoding="utf-8",
        errors="strict",
    )

    old_paths = sorted(
        set(
            re.findall(
                r"smali(?:_classes\d+)?/"
                r"com/samsung/android/settings/security/"
                r"PowerOffLockPreferenceController\.smali",
                patch_text,
            )
        )
    )

    if not old_paths:
        abort("caminho da classe não encontrado no patch original")

    for old_path in old_paths:
        patch_text = patch_text.replace(
            old_path,
            relative,
        )

    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=".patch",
        delete=False,
    ) as temporary:
        temporary.write(patch_text)
        temporary_path = Path(temporary.name)

    try:
        process = subprocess.run(
            [
                "patch",
                "-p1",
                "-d",
                str(decoded),
                "-N",
                "--forward",
                "-l",
                "--batch",
                "-i",
                str(temporary_path),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
    finally:
        temporary_path.unlink(missing_ok=True)

    print(process.stdout, end="")

    if process.returncode != 0:
        abort(
            "o hunk de Power Off Lock não corresponde "
            "ao código da One UI 9"
        )

    final_smali = smali.read_text(
        encoding="utf-8",
        errors="strict",
    )

    failures: list[str] = []

    if COUNTRY_CALL in final_smali:
        failures.append("a restrição de país ainda existe")

    if 'const-string p0, "BR"' in final_smali:
        failures.append('a comparação com o país "BR" ainda existe')

    if 'const/4 p0, 0x0' not in final_smali:
        failures.append("retorno disponível 0 ausente")

    if 'const/4 p0, 0x3' not in final_smali:
        failures.append("retorno indisponível 3 ausente")

    reject = Path(str(smali) + ".rej")

    if reject.exists():
        failures.append(f"reject restante: {reject}")

    if failures:
        abort(
            "validação do Power Off Lock falhou: "
            + "; ".join(failures)
        )

    print("OK: restrição regional do Power Off Lock removida")
    print("OK: patch de Power Off Lock completamente validado")


if __name__ == "__main__":
    main()
