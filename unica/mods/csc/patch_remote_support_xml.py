#!/usr/bin/env python3

from __future__ import annotations

import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


REMOTE_PATTERN = re.compile(
    r"remote.?support|remote_support|remotesupport|"
    r"remote.?management|smart.?tutor",
    re.IGNORECASE,
)

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ANDROID_KEY = f"{{{ANDROID_NS}}}key"


def abort(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def local_name(tag: object) -> str:
    if not isinstance(tag, str):
        return "comment"

    return tag.rsplit("}", 1)[-1]


def register_namespaces(path: Path) -> None:
    try:
        namespaces = dict(
            ET.iterparse(path, events=("start-ns",))
        )
    except ET.ParseError as error:
        abort(f"XML inválido em {path}: {error}")

    for prefix, uri in namespaces.items():
        try:
            ET.register_namespace(prefix or "", uri)
        except ValueError:
            pass


def element_text(element: ET.Element) -> str:
    values = [local_name(element.tag)]

    if element.text:
        values.append(element.text)

    for name, value in element.attrib.items():
        values.append(local_name(name))
        values.append(value)

    return " ".join(values)


def choose_preference(
    element: ET.Element,
    root: ET.Element,
    parents: dict[ET.Element, ET.Element],
) -> ET.Element:
    current = element

    while current is not root:
        tag = local_name(current.tag).lower()

        if (
            "preference" in tag
            or tag in {"item", "switchbar"}
        ):
            return current

        parent = parents.get(current)

        if parent is None:
            break

        current = parent

    # Fallback: remove somente o filho direto da raiz
    # que contém a referência, nunca a raiz inteira.
    current = element

    while parents.get(current) is not root:
        parent = parents.get(current)

        if parent is None:
            abort(
                "não foi possível determinar o nó XML "
                "da preferência Remote Support"
            )

        current = parent

    return current


def patch_file(path: Path) -> int:
    register_namespaces(path)

    parser = ET.XMLParser(
        target=ET.TreeBuilder(insert_comments=True)
    )

    try:
        tree = ET.parse(path, parser=parser)
    except ET.ParseError as error:
        abort(f"não foi possível analisar {path}: {error}")

    root = tree.getroot()

    parents = {
        child: parent
        for parent in root.iter()
        for child in parent
    }

    matches = [
        element
        for element in root.iter()
        if element is not root
        and REMOTE_PATTERN.search(element_text(element))
    ]

    if not matches:
        print(f"OK: Remote Support já está ausente de {path}")
        return 0

    targets: list[ET.Element] = []

    for element in matches:
        target = choose_preference(
            element,
            root,
            parents,
        )

        if target not in targets:
            targets.append(target)

    if not targets:
        abort(
            f"referência encontrada, mas nenhum nó removível "
            f"foi identificado em {path}"
        )

    backup = path.with_suffix(
        path.suffix + ".bak-unica-remote-support"
    )

    if not backup.exists():
        shutil.copy2(path, backup)

    removed = 0

    for target in targets:
        parent = parents.get(target)

        if parent is None:
            abort(
                "o nó selecionado não possui pai; "
                "recusando remover a raiz"
            )

        key = target.attrib.get(ANDROID_KEY, "")
        tag = local_name(target.tag)

        print(
            f"Removendo <{tag}> "
            f"android:key={key!r} de {path}"
        )

        parent.remove(target)
        removed += 1

    temporary = path.with_suffix(
        path.suffix + ".unica.tmp"
    )

    tree.write(
        temporary,
        encoding="utf-8",
        xml_declaration=True,
        short_empty_elements=True,
    )

    try:
        validation_tree = ET.parse(temporary)
    except ET.ParseError as error:
        temporary.unlink(missing_ok=True)
        abort(f"XML modificado ficou inválido: {error}")

    remaining = [
        element
        for element in validation_tree.getroot().iter()
        if REMOTE_PATTERN.search(element_text(element))
    ]

    if remaining:
        temporary.unlink(missing_ok=True)
        abort(
            f"a referência Remote Support permaneceu em {path}"
        )

    temporary.replace(path)

    print(
        f"OK: {removed} preferência(s) Remote Support "
        f"removida(s) de {path}"
    )

    return removed


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: patch_remote_support_xml.py "
            "<SecSettings.apk decodificado>"
        )

    decoded_apk = Path(sys.argv[1])

    if not decoded_apk.is_dir():
        abort(
            f"SecSettings.apk decodificado não encontrado: "
            f"{decoded_apk}"
        )

    xml_files = sorted(
        decoded_apk.glob(
            "res/xml*/meta_009_settings.xml"
        )
    )

    if not xml_files:
        abort(
            "meta_009_settings.xml não encontrado "
            "em nenhum res/xml*"
        )

    total = 0
    processed = 0

    for xml_file in xml_files:
        content = xml_file.read_text(
            encoding="utf-8",
            errors="replace",
        )

        if not REMOTE_PATTERN.search(content):
            continue

        processed += 1
        total += patch_file(xml_file)

    if processed == 0:
        print(
            "OK: meta_009_settings.xml existe, mas "
            "Remote Support já está ausente"
        )
        return

    if total == 0:
        abort(
            "Remote Support foi localizado, mas nenhum "
            "nó XML foi removido"
        )

    print(
        "OK: remoção XML do Remote Support validada; "
        f"total removido: {total}"
    )


if __name__ == "__main__":
    main()
