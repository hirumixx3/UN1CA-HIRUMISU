DAAGENT_APK="system/app/DAAgent/DAAgent.apk"
DAAGENT_PATCH="$MODPATH/smali/system/app/DAAgent/DAAgent.apk/0001-Allow-all-apps-in-Dual-Messenger.patch.disabled-oneui9"

if ! APPLY_PATCH \
        "system" \
        "$DAAGENT_APK" \
        "$DAAGENT_PATCH"; then
    LOG "! DAAgent diff partially applied; validating pre-patched One UI 9 receiver"
fi

DAAGENT_DIR="$APKTOOL_DIR/system/app/DAAgent/DAAgent.apk"

python3 \
    "$MODPATH/repair_daagent_receiver_oneui9.py" \
    "$DAAGENT_DIR" \
    || ABORT "Failed to repair DualAppIntentReceiver package events"

python3 \
    "$MODPATH/validate_daagent_oneui9.py" \
    "$DAAGENT_DIR" \
    || ABORT "Dual Messenger all-apps patch is incomplete"

LOG "- Dual Messenger all-apps patch fully validated"

unset DAAGENT_APK
unset DAAGENT_PATCH
unset DAAGENT_DIR
