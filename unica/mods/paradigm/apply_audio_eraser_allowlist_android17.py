#!/usr/bin/env python3

from pathlib import Path
import hashlib
import re
import sys


CLASS_NAME = (
    "AudioEraserAudioPlaybackStartable$audioPlaybackCallback$1"
    "$onPlaybackConfigChanged$1.smali"
)

OWNER = (
    "Lcom/android/systemui/samsung/quicksetting/ui/banner/"
    "AudioEraserAudioPlaybackStartable;"
)

CHECK_LABEL = ":cond_unica_local_audio_eraser_check"
ALLOW_LABEL = ":cond_unica_local_audio_eraser_allow"
NEXT_LABEL = ":cond_unica_local_audio_eraser_next"
LOOP_LABEL = ":goto_unica_local_audio_eraser"


def fail(message: str, context: str = "") -> None:
    print(f"ERRO: {message}", file=sys.stderr)

    if context:
        print(
            "\n===== CONTEXTO DO MÉTODO =====",
            file=sys.stderr,
        )
        print(context, file=sys.stderr)

    raise SystemExit(1)


def locate_target(decoded: Path) -> Path:
    matches = list(decoded.rglob(CLASS_NAME))

    if len(matches) != 1:
        fail(
            f"{CLASS_NAME} encontrado {len(matches)} vez(es)"
        )

    return matches[0]


def locate_method(text: str) -> tuple[int, int, str]:
    active = text.find(
        f"{OWNER}->activePlaybacks:Ljava/util/Map;"
    )

    if active < 0:
        fail("campo activePlaybacks não encontrado")

    starts = list(
        re.finditer(
            r"^\.method[^\n]*$",
            text[:active],
            flags=re.MULTILINE,
        )
    )

    if not starts:
        fail("início do método callback não encontrado")

    start = starts[-1].start()
    end = text.find("\n.end method", active)

    if end < 0:
        fail("final do método callback não encontrado")

    end += len("\n.end method")

    return start, end, text[start:end]


def locate_active(method: str) -> re.Match:
    pattern = re.compile(
        r"^[ \t]*iget-object\s+[vp]\d+,\s*v1,\s*"
        + re.escape(OWNER)
        + r"->activePlaybacks:Ljava/util/Map;\s*$",
        flags=re.MULTILINE,
    )

    match = pattern.search(method)

    if not match:
        fail(
            "instrução iget-object de activePlaybacks "
            "não encontrada",
            method,
        )

    return match


def find_original_branch(
    method: str,
    active_position: int,
) -> tuple[re.Match, str, str]:
    before_active = method[:active_position]

    pattern = re.compile(
        r"^[ \t]*if-eqz\s+"
        r"(?P<register>[vp]\d+),\s*"
        r"(?P<label>:cond_[A-Za-z0-9_]+)\s*$",
        flags=re.MULTILINE,
    )

    candidates = list(pattern.finditer(before_active))

    if not candidates:
        fail(
            "nenhum if-eqz encontrado antes de activePlaybacks",
            method,
        )

    # O branch correto é o último if-eqz antes da inclusão
    # no mapa activePlaybacks.
    branch = candidates[-1]

    distance = active_position - branch.end()

    if distance > 500:
        fail(
            "o if-eqz mais próximo está longe demais de "
            f"activePlaybacks ({distance} caracteres)",
            method,
        )

    return (
        branch,
        branch.group("register"),
        branch.group("label"),
    )


def find_package_register(method: str) -> str:
    # Quando o hunk 2 já aplicou, extraímos diretamente
    # o registrador utilizado pelo bloco parcial.
    partial = re.search(
        r"invoke-virtual\s+\{v10,\s*(?P<register>[vp]\d+)\},\s*"
        r"Ljava/lang/String;->equals"
        r"\(Ljava/lang/Object;\)Z",
        method,
    )

    if partial:
        return partial.group("register")

    active = locate_active(method)
    before_active = method[:active.start()]

    # Procura o objeto passado a List/Set/Collection.contains().
    contains_pattern = re.compile(
        r"invoke-(?:interface|virtual)\s+"
        r"\{\s*[vp]\d+,\s*(?P<register>[vp]\d+)\s*\},\s*"
        r"Ljava/util/(?:List|Set|Collection);->contains"
        r"\(Ljava/lang/Object;\)Z"
    )

    contains = list(
        contains_pattern.finditer(before_active)
    )

    if contains:
        return contains[-1].group("register")

    # O patch upstream usa v11 e o método desta base ainda
    # possui esse registrador.
    if re.search(r"\bv11\b", method):
        return "v11"

    fail(
        "não foi possível identificar o registrador "
        "do nome do pacote",
        method,
    )


def label_count(method: str, label: str) -> int:
    return len(
        re.findall(
            r"^[ \t]*"
            + re.escape(label)
            + r"[ \t]*$",
            method,
            flags=re.MULTILINE,
        )
    )


def main() -> None:
    if len(sys.argv) != 2:
        fail(
            "uso: apply_audio_eraser_allowlist_android17.py "
            "<SystemUI.apk decompilado>"
        )

    decoded = Path(sys.argv[1]).resolve()

    if not decoded.is_dir():
        fail(
            f"SystemUI decompilado não encontrado: {decoded}"
        )

    target = locate_target(decoded)

    text = target.read_text(
        encoding="utf-8",
        errors="strict",
    )

    method_start, method_end, method = locate_method(text)
    active = locate_active(method)

    branch, branch_register, fallback_label = (
        find_original_branch(
            method,
            active.start(),
        )
    )

    package_register = find_package_register(method)

    print(
        f"Audio Eraser alvo: {target.relative_to(decoded)}"
    )
    print(
        f"Branch original: if-eqz {branch_register}, "
        f"{fallback_label}"
    )
    print(f"Registrador do pacote: {package_register}")

    # Adiciona o label de pacote permitido exatamente antes
    # da inclusão em activePlaybacks.
    if label_count(method, ALLOW_LABEL) == 0:
        method = (
            method[:active.start()]
            + f"    {ALLOW_LABEL}\n"
            + method[active.start():]
        )

        print("Label de pacote permitido inserido.")
    elif label_count(method, ALLOW_LABEL) == 1:
        print("Label de pacote permitido já presente.")
    else:
        fail(
            f"{ALLOW_LABEL} está duplicado",
            method,
        )

    active = locate_active(method)

    # O hunk 2 da tentativa anterior normalmente já inseriu
    # este bloco. Em build limpa, o helper o cria.
    if label_count(method, CHECK_LABEL) == 0:
        fallback_declaration = re.search(
            r"^[ \t]*"
            + re.escape(fallback_label)
            + r"[ \t]*$",
            method,
            flags=re.MULTILINE,
        )

        if not fallback_declaration:
            fail(
                f"declaração de {fallback_label} não encontrada",
                method,
            )

        block = f'''    {CHECK_LABEL}
    iget-object v0, v1, {OWNER}->context:Landroid/content/Context;

    if-eqz v0, {fallback_label}

    invoke-virtual {{v0}}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object v0

    const-string/jumbo v9, "unica_scpm_allowlist_packages"

    invoke-static {{v0, v9}}, Landroid/provider/Settings$System;->getString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    if-eqz v0, {fallback_label}

    const-string v9, "\\n"

    invoke-virtual {{v0, v9}}, Ljava/lang/String;->split(Ljava/lang/String;)[Ljava/lang/String;

    move-result-object v0

    const/4 v9, 0x0

    {LOOP_LABEL}
    array-length v10, v0

    if-ge v9, v10, {fallback_label}

    aget-object v10, v0, v9

    invoke-virtual {{v10}}, Ljava/lang/String;->trim()Ljava/lang/String;

    move-result-object v10

    invoke-virtual {{v10, {package_register}}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v10

    if-eqz v10, {NEXT_LABEL}

    goto {ALLOW_LABEL}

    {NEXT_LABEL}
    add-int/lit8 v9, v9, 0x1

    goto {LOOP_LABEL}

'''

        method = (
            method[:fallback_declaration.start()]
            + block
            + method[fallback_declaration.start():]
        )

        print("Bloco da allowlist local inserido.")
    elif label_count(method, CHECK_LABEL) == 1:
        print(
            "Bloco parcial da allowlist já estava presente."
        )
    else:
        fail(
            f"{CHECK_LABEL} está duplicado",
            method,
        )

    # O método pode ter mudado após as inserções.
    active = locate_active(method)

    # Encontra novamente o branch imediatamente anterior.
    branch_pattern = re.compile(
        r"^[ \t]*if-eqz\s+"
        + re.escape(branch_register)
        + r",\s*"
        + re.escape(fallback_label)
        + r"\s*$",
        flags=re.MULTILINE,
    )

    before_active = method[:active.start()]
    branches = list(
        branch_pattern.finditer(before_active)
    )

    already_redirected = re.search(
        r"^[ \t]*if-eqz\s+"
        + re.escape(branch_register)
        + r",\s*"
        + re.escape(CHECK_LABEL)
        + r"\s*$",
        before_active,
        flags=re.MULTILINE,
    )

    if already_redirected:
        print("Branch já estava redirecionado.")
    elif branches:
        branch = branches[-1]

        replacement = (
            f"    if-eqz {branch_register}, {CHECK_LABEL}"
        )

        method = (
            method[:branch.start()]
            + replacement
            + method[branch.end():]
        )

        print(
            f"Branch {fallback_label} redirecionado "
            "para a allowlist local."
        )
    else:
        fail(
            "branch original não foi encontrado para "
            "redirecionamento",
            method,
        )

    modified = (
        text[:method_start]
        + method
        + text[method_end:]
    )

    # Validação final.
    _, _, final_method = locate_method(modified)

    validations = {
        "branch redirecionado": bool(
            re.search(
                r"if-eqz\s+"
                + re.escape(branch_register)
                + r",\s*"
                + re.escape(CHECK_LABEL),
                final_method,
            )
        ),
        "check único": (
            label_count(final_method, CHECK_LABEL) == 1
        ),
        "allow único": (
            label_count(final_method, ALLOW_LABEL) == 1
        ),
        "next único": (
            label_count(final_method, NEXT_LABEL) == 1
        ),
        "loop único": (
            label_count(final_method, LOOP_LABEL) == 1
        ),
        "chave Settings.System": (
            '"unica_scpm_allowlist_packages"'
            in final_method
        ),
        "comparação de pacote": bool(
            re.search(
                r"invoke-virtual\s+\{v10,\s*"
                + re.escape(package_register)
                + r"\},\s*Ljava/lang/String;->equals",
                final_method,
            )
        ),
        "fallback existe": bool(
            re.search(
                r"^[ \t]*"
                + re.escape(fallback_label)
                + r"[ \t]*$",
                final_method,
                flags=re.MULTILINE,
            )
        ),
    }

    failed = [
        name
        for name, passed in validations.items()
        if not passed
    ]

    if failed:
        fail(
            "validação final falhou: "
            + ", ".join(failed),
            final_method,
        )

    target.write_text(
        modified,
        encoding="utf-8",
    )

    for extension in (".rej", ".orig"):
        garbage = Path(str(target) + extension)

        if garbage.exists():
            garbage.unlink()

    digest = hashlib.sha256(
        target.read_bytes()
    ).hexdigest()

    print("Validação semântica: OK")
    print(f"SHA-256 smali: {digest}")


if __name__ == "__main__":
    main()
