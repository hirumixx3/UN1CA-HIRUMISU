SET_PROP_IF_DIFF "vendor" "ro.oem_unlock_supported" "0"

# Better device/model detection in CoreRune
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes6/com/samsung/android/rune/CoreRune.smali" "replace" \
    '<clinit>()V' \
    'ro.product.model' \
    'ro.product.vendor.model'
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes6/com/samsung/android/rune/CoreRune.smali" "replace" \
    '<clinit>()V' \
    'ro.product.device' \
    'ro.product.vendor.device'

# Disable Samsung RescueParty on One UI 9
DECODE_APK \
    "system" \
    "system/framework/services.jar"

RESCUE_SMALI="$APKTOOL_DIR/system/framework/services.jar/smali/com/android/server/SecRescueParty.smali"

if [ ! -f "$RESCUE_SMALI" ]; then
    ABORT "SecRescueParty.smali not found after decoding services.jar"
fi

LOG "- Disabling SecRescueParty health observer registration"

python3 - "$RESCUE_SMALI" <<'PYTHON' || \
    ABORT "Failed to patch SecRescueParty registration method"
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(
    encoding="utf-8",
    errors="strict",
).splitlines(keepends=True)

signature = (
    "secRescuePartyRegisterHealthObserver"
    "(Landroid/content/Context;)V"
)

starts = [
    index
    for index, line in enumerate(lines)
    if line.strip().startswith(".method")
    and signature in line
]

if len(starts) != 1:
    raise SystemExit(
        f"Expected exactly one {signature} method; "
        f"found {len(starts)}"
    )

start = starts[0]

end = None
for index in range(start + 1, len(lines)):
    if lines[index].strip() == ".end method":
        end = index
        break

if end is None:
    raise SystemExit("Method end not found")

method_header = lines[start].rstrip("\n")

new_method = [
    method_header + "\n",
    "    .locals 0\n",
    "\n",
    "    return-void\n",
    ".end method\n",
]

current_body = "".join(lines[start:end + 1])

if (
    ".locals 0" in current_body
    and "return-void" in current_body
    and current_body.count("return-void") == 1
):
    print("OK: method already patched")
    raise SystemExit(0)

lines[start:end + 1] = new_method

path.write_text(
    "".join(lines),
    encoding="utf-8",
)

validated = path.read_text(
    encoding="utf-8",
    errors="strict",
)

if signature not in validated:
    raise SystemExit("Method disappeared after patch")

print(
    "OK: secRescuePartyRegisterHealthObserver "
    "replaced with return-void"
)
PYTHON

unset RESCUE_SMALI

# Better model detection in FreecessController
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/am/FreecessController.smali" "replace" \
    '<clinit>()V' \
    'ro.product.model' \
    'ro.product.vendor.model'

# BEGIN ONEUI9 VENDOR MISMATCH PATCH
DECODE_APK \
    "system" \
    "system/framework/services.jar" \
    || ABORT "Failed to decode services.jar for vendor mismatch patch"

VENDOR_MISMATCH_SERVICES="$APKTOOL_DIR/system/framework/services.jar"

LOG "- Disabling vendor mismatch warning dialog semantically"

python3 \
    "$MODPATH/patch_vendor_mismatch_oneui9.py" \
    "$VENDOR_MISMATCH_SERVICES" \
    || ABORT "Failed to disable vendor mismatch warning dialog"

unset VENDOR_MISMATCH_SERVICES
# END ONEUI9 VENDOR MISMATCH PATCH
