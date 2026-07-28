#!/usr/bin/env python3

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ANDROID_NS = "http://schemas.android.com/apk/res/android"
ANDROID_NAME = f"{{{ANDROID_NS}}}name"
ANDROID_SCHEME = f"{{{ANDROID_NS}}}scheme"

UPDATE_CALL = (
    "Lcom/samsung/android/da/daagent/utils/DAUtility;"
    "->updateWhitelistAppsInSystemServer"
    "(Landroid/content/Context;)V"
)

REFRESH_CALL = (
    "Lcom/samsung/android/da/daagent/provider/WhiteListApps;"
    "->refreshWhiteList(Landroid/content/Context;)V"
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


def local_name(tag: object) -> str:
    if not isinstance(tag, str):
        return ""

    return tag.rsplit("}", 1)[-1]


def validate_manifest(manifest: Path) -> None:
    try:
        tree = ET.parse(manifest)
    except ET.ParseError as error:
        abort(f"AndroidManifest.xml inválido: {error}")

    receivers = [
        element
        for element in tree.getroot().iter()
        if local_name(element.tag) == "receiver"
        and element.attrib.get(
            ANDROID_NAME,
            "",
        ).endswith(
            ".receiver.DualAppIntentReceiver"
        )
    ]

    if len(receivers) != 1:
        abort(
            "esperava um DualAppIntentReceiver no manifesto; "
            f"encontrei {len(receivers)}"
        )

    receiver = receivers[0]

    actions = {
        element.attrib.get(ANDROID_NAME, "")
        for element in receiver.iter()
        if local_name(element.tag) == "action"
    }

    schemes = {
        element.attrib.get(ANDROID_SCHEME, "")
        for element in receiver.iter()
        if local_name(element.tag) == "data"
    }

    required_actions = {
        "android.intent.action.PACKAGE_ADDED",
        "android.intent.action.PACKAGE_REMOVED",
    }

    missing = required_actions - actions

    if missing:
        abort(
            "ações ausentes do Manifest: "
            + ", ".join(sorted(missing))
        )

    if "package" not in schemes:
        abort(
            'android:scheme="package" ausente do '
            "DualAppIntentReceiver"
        )

    print("OK: eventos de instalação/remoção presentes no Manifest")


def validate_receiver(path: Path) -> None:
    text = read(path)

    checks = {
        "PACKAGE_ADDED": (
            '"android.intent.action.PACKAGE_ADDED"' in text
        ),
        "PACKAGE_REMOVED": (
            '"android.intent.action.PACKAGE_REMOVED"' in text
        ),
        "atualização dinâmica da whitelist": (
            text.count(UPDATE_CALL) >= 2
        ),
        "método onReceive": (
            ".method public onReceive("
            "Landroid/content/Context;"
            "Landroid/content/Intent;)V"
            in text
            or
            ".method public final onReceive("
            "Landroid/content/Context;"
            "Landroid/content/Intent;)V"
            in text
        ),
    }

    failures = [
        description
        for description, passed in checks.items()
        if not passed
    ]

    if failures:
        abort(
            "DualAppIntentReceiver incompleto: "
            + "; ".join(failures)
        )

    print(
        "OK: DualAppIntentReceiver já contém todos "
        "os hunks necessários"
    )


def validate_whitelist(path: Path) -> None:
    text = read(path)

    required = {
        "campo sAppsListCount": (
            "sAppsListCount:I" in text
        ),
        "método refreshWhiteList": (
            ".method public static refreshWhiteList("
            "Landroid/content/Context;)V"
            in text
        ),
        "consulta de apps com launcher": (
            "->queryIntentActivities("
            "Landroid/content/Intent;I)"
            "Ljava/util/List;"
            in text
        ),
        "filtro install_only_owner": (
            "com.samsung.android.multiuser.install_only_owner"
            in text
        ),
    }

    forbidden = {
        "CHINA_SALES_CODES": "lista regional antiga",
        "DUAL_APP_WHITELIST_PACKAGES_FOR_CHINA": (
            "whitelist chinesa antiga"
        ),
        "decodeString(Ljava/lang/String;)": (
            "decoder da whitelist fixa"
        ),
    }

    failures = [
        description
        for description, passed in required.items()
        if not passed
    ]

    failures.extend(
        description
        for token, description in forbidden.items()
        if token in text
    )

    if failures:
        abort(
            "WhiteListApps incompleto: "
            + "; ".join(failures)
        )

    print("OK: WhiteListApps usa lista dinâmica de aplicativos")


def validate_provider(path: Path) -> None:
    text = read(path)

    if (
        "DUAL_APP_WHITELIST_PACKAGES_FOR_CHINA"
        in text
        or "CHINA_SALES_CODES" in text
    ):
        abort(
            "DualAppProvider ainda possui seleção "
            "regional da whitelist"
        )

    if (
        "WhiteListApps;"
        "->DUAL_APP_WHITELIST_PACKAGES:"
        "[Ljava/lang/String;"
        not in text
    ):
        abort(
            "DualAppProvider não usa "
            "DUAL_APP_WHITELIST_PACKAGES"
        )

    print("OK: DualAppProvider usa a whitelist dinâmica")


def validate_utility(path: Path) -> None:
    text = read(path)

    if REFRESH_CALL not in text:
        abort(
            "DAUtility não chama WhiteListApps.refreshWhiteList"
        )

    forbidden = [
        "CHINA_SALES_CODES",
        "DUAL_APP_WHITELIST_PACKAGES_FOR_CHINA",
    ]

    remaining = [
        token
        for token in forbidden
        if token in text
    ]

    if remaining:
        abort(
            "DAUtility ainda possui lógica regional antiga: "
            + ", ".join(remaining)
        )

    print("OK: DAUtility atualiza a whitelist antes de enviá-la")


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: validate_daagent_oneui9.py "
            "<DAAgent.apk decodificado>"
        )

    root = Path(sys.argv[1])

    if not root.is_dir():
        abort(f"DAAgent decodificado não encontrado: {root}")

    manifest = root / "AndroidManifest.xml"

    if not manifest.is_file():
        abort("AndroidManifest.xml não encontrado")

    provider = find_one(
        root,
        "com/samsung/android/da/daagent/provider/"
        "DualAppProvider.smali",
    )

    whitelist = find_one(
        root,
        "com/samsung/android/da/daagent/provider/"
        "WhiteListApps.smali",
    )

    receiver = find_one(
        root,
        "com/samsung/android/da/daagent/receiver/"
        "DualAppIntentReceiver.smali",
    )

    utility = find_one(
        root,
        "com/samsung/android/da/daagent/utils/"
        "DAUtility.smali",
    )

    validate_manifest(manifest)
    validate_provider(provider)
    validate_whitelist(whitelist)
    validate_receiver(receiver)
    validate_utility(utility)

    rejects = list(root.rglob("*.rej"))

    if rejects:
        print("Rejects reconhecidos após validação:")

        for reject in rejects:
            print(f"  {reject}")

        unexpected = [
            reject
            for reject in rejects
            if reject.name
            != "DualAppIntentReceiver.smali.rej"
        ]

        if unexpected:
            abort(
                "existem rejects inesperados:\n"
                + "\n".join(
                    str(reject)
                    for reject in unexpected
                )
            )

        for reject in rejects:
            reject.unlink()

        print(
            "OK: reject do receiver já aplicado "
            "foi removido"
        )

    print()
    print(
        "OK: Dual Messenger para todos os apps "
        "completamente aplicado"
    )


if __name__ == "__main__":
    main()
