#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path


OLD_MESSAGE = "Build fingerprint is not consistent, warning user"
NEW_MESSAGE = "Build fingerprint is not consistent"
MARKER = "# UN1CA_ONEUI9_VENDOR_MISMATCH_DIALOG_DISABLED"


def fail(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("informe o diretório decodificado do services.jar")

    root = Path(sys.argv[1])

    if not root.is_dir():
        fail(f"services.jar decodificado não encontrado: {root}")

    smali_files = list(root.rglob("*.smali"))

    already_patched = []
    candidates = []

    for path in smali_files:
        text = path.read_text(
            encoding="utf-8",
            errors="replace",
        )

        if MARKER in text:
            already_patched.append(path)

        if OLD_MESSAGE in text:
            candidates.append(path)

    if not candidates:
        if len(already_patched) == 1:
            print(f"OK: patch já aplicado em {already_patched[0]}")
            return

        fail(
            "mensagem de vendor mismatch não encontrada "
            "e o marcador do patch também não existe"
        )

    if len(candidates) != 1:
        fail(
            f"esperava uma classe com a mensagem; "
            f"encontrei {len(candidates)}"
        )

    path = candidates[0]
    lines = path.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    hits = [
        index
        for index, line in enumerate(lines)
        if OLD_MESSAGE in line
    ]

    if len(hits) != 1:
        fail(
            f"esperava uma ocorrência da mensagem em {path}; "
            f"encontrei {len(hits)}"
        )

    hit = hits[0]

    method_start = None
    for index in range(hit, -1, -1):
        if lines[index].lstrip().startswith(".method"):
            method_start = index
            break

    if method_start is None:
        fail("início do método não encontrado")

    method_end = None
    for index in range(hit, len(lines)):
        if lines[index].strip() == ".end method":
            method_end = index
            break

    if method_end is None:
        fail("final do método não encontrado")

    slog_index = None
    for index in range(hit, min(method_end + 1, hit + 25)):
        if (
            "Landroid/util/Slog;->e("
            "Ljava/lang/String;Ljava/lang/String;)I"
        ) in lines[index]:
            slog_index = index
            break

    if slog_index is None:
        fail("chamada Slog.e após a mensagem não encontrada")

    post_index = None
    for index in range(
        slog_index + 1,
        min(method_end + 1, slog_index + 100),
    ):
        if (
            "Landroid/os/Handler;->post("
            "Ljava/lang/Runnable;)Z"
        ) in lines[index]:
            post_index = index
            break

    if post_index is None:
        fail("Handler.post do aviso não encontrado")

    block = lines[slog_index + 1:post_index + 1]

    meaningful = [
        line.strip()
        for line in block
        if line.strip() and not line.lstrip().startswith("#")
    ]

    dangerous = [
        line
        for line in meaningful
        if line.startswith(":")
        or line.startswith(".")
        or line.startswith("packed-switch")
        or line.startswith("sparse-switch")
    ]

    if dangerous:
        fail(
            "o bloco contém labels ou diretivas; "
            "recusando alteração insegura: "
            + ", ".join(dangerous)
        )

    if not any("Ljava/lang/Runnable;" in line for line in meaningful):
        fail("o bloco não contém criação/uso de Runnable")

    if not any("mUiHandler" in line for line in meaningful):
        fail("o bloco não referencia mUiHandler")

    lines[hit] = lines[hit].replace(
        OLD_MESSAGE,
        NEW_MESSAGE,
        1,
    )

    indent = lines[slog_index][
        :len(lines[slog_index])
        - len(lines[slog_index].lstrip())
    ]

    marker_line = f"{indent}{MARKER}\n"

    removed_count = post_index - slog_index

    lines[slog_index + 1:post_index + 1] = [
        "\n",
        marker_line,
    ]

    path.write_text(
        "".join(lines),
        encoding="utf-8",
    )

    final = path.read_text(
        encoding="utf-8",
        errors="strict",
    )

    if OLD_MESSAGE in final:
        fail("mensagem original permaneceu após o patch")

    if MARKER not in final:
        fail("marcador de validação não foi gravado")

    print(f"OK: vendor mismatch dialog desativado em {path}")
    print(f"Método: {lines[method_start].strip()}")
    print(f"Linhas de agendamento removidas: {removed_count}")
    print("O erro continuará sendo registrado no log, sem abrir diálogo.")


if __name__ == "__main__":
    main()
