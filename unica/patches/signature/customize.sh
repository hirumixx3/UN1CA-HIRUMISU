CERT_PREFIX="aosp"
$ROM_IS_OFFICIAL && CERT_PREFIX="unica"

CERT_FILE="$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem"

if [ ! -f "$CERT_FILE" ]; then
    ABORT "File not found: security/${CERT_PREFIX}_platform.x509.pem"
fi

if ! APPLY_PATCH \
        "system" \
        "system/framework/services.jar" \
        "$MODPATH/services.jar/0001-Allow-custom-platform-signature.patch"; then
    LOG "! Signature diff partially applied; repairing One UI 9 rejects"
fi

SIGNATURE_SERVICES="$APKTOOL_DIR/system/framework/services.jar"

python3 \
    "$MODPATH/repair_signature_oneui9.py" \
    "$SIGNATURE_SERVICES" \
    || ABORT "Custom platform signature spoof is incomplete"


python3 \
    "$MODPATH/repair_signature_invokes_oneui9.py" \
    "$SIGNATURE_SERVICES" \
    || ABORT "Custom platform signature invokes are invalid"

python3 - "$SIGNATURE_SERVICES" "$CERT_FILE" <<'PYTHON' || \
    ABORT "Custom platform certificate injection failed"
from pathlib import Path
import base64
import sys

root = Path(sys.argv[1])
cert_path = Path(sys.argv[2])

matches = list(root.rglob("InstallPackageHelper.smali"))

if len(matches) != 1:
    raise SystemExit(
        "Expected one InstallPackageHelper.smali; "
        f"found {len(matches)}"
    )

install = matches[0]

pem_lines = [
    line.strip()
    for line in cert_path.read_text(
        encoding="ascii",
        errors="strict",
    ).splitlines()
    if line
    and not line.startswith("-----")
]

certificate_hex = base64.b64decode(
    "".join(pem_lines),
    validate=True,
).hex()

text = install.read_text(
    encoding="utf-8",
    errors="strict",
)

placeholder = "CONFIG_CUSTOM_PLATFORM_SIGNATURE"
count = text.count(placeholder)

if count != 1:
    raise SystemExit(
        f"Expected one certificate placeholder; found {count}"
    )

text = text.replace(
    placeholder,
    certificate_hex,
    1,
)

install.write_text(
    text,
    encoding="utf-8",
)

final = install.read_text(
    encoding="utf-8",
    errors="strict",
)

if placeholder in final:
    raise SystemExit("Certificate placeholder remains")

if certificate_hex not in final:
    raise SystemExit("Configured certificate was not injected")

print(
    "OK: platform certificate injected "
    f"({len(certificate_hex) // 2} DER bytes)"
)
PYTHON

LOG "- Custom platform signature spoof fully validated"

unset CERT_PREFIX CERT_FILE SIGNATURE_SERVICES

