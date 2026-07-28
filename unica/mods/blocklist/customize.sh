DELETE_FROM_WORK_DIR \
    "system" \
    "system/etc/ldu_blocklist.xml"

CUSTOM_BLOCKLIST="$WORK_DIR/system/system/etc/unica_blocklist.xml"

if [ ! -s "$CUSTOM_BLOCKLIST" ]; then
    ABORT "Custom blocklist file missing or empty: $CUSTOM_BLOCKLIST"
fi

if ! APPLY_PATCH \
        "system" \
        "system/framework/services.jar" \
        "$MODPATH/services.jar/0001-Allow-custom-PackageBlockListPolicy.patch"; then
    LOG "! Blocklist diff partially applied; repairing One UI 9 rejects"
fi

BLOCKLIST_SERVICES="$APKTOOL_DIR/system/framework/services.jar"

python3 \
    "$MODPATH/repair_blocklist_oneui9.py" \
    "$BLOCKLIST_SERVICES" \
    || ABORT "Custom PackageBlockListPolicy patch is incomplete"

LOG "- Custom PackageBlockListPolicy fully validated"

unset CUSTOM_BLOCKLIST
unset BLOCKLIST_SERVICES
