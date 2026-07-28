PATCH_CSC_RETURN_DYNAMIC()
{
    local PARTITION="$1"
    local APK_FILE="$2"
    local CLASS_PATH="$3"
    local METHOD="$4"
    local VALUE="$5"

    local RELATIVE_APK
    local DECODED_DIR
    local SMALI_ABS
    local SMALI_REL
    local COUNT

    DECODE_APK "$PARTITION" "$APK_FILE" || \
        ABORT "Failed to decode /$PARTITION/$APK_FILE"

    RELATIVE_APK="$APK_FILE"

    if [ "$PARTITION" = "system" ]; then
        RELATIVE_APK="${RELATIVE_APK#system/}"
    fi

    DECODED_DIR="$APKTOOL_DIR/$PARTITION/$RELATIVE_APK"

    COUNT="$(
        find "$DECODED_DIR" \
            -type f \
            -path "*/$CLASS_PATH" \
            -print 2>/dev/null |
        wc -l
    )"

    if [ "$COUNT" -ne 1 ]; then
        ABORT \
            "Expected exactly one $CLASS_PATH, found $COUNT"
    fi

    SMALI_ABS="$(
        find "$DECODED_DIR" \
            -type f \
            -path "*/$CLASS_PATH" \
            -print \
            -quit
    )"

    SMALI_REL="${SMALI_ABS#"$DECODED_DIR"/}"

    LOG "- Using dynamically detected $SMALI_REL"

    SMALI_PATCH \
        "$PARTITION" \
        "$APK_FILE" \
        "$SMALI_REL" \
        "return" \
        "$METHOD" \
        "$VALUE" \
        || ABORT "Failed to patch $METHOD"
}

# Enable Power off lock feature.
PATCH_CSC_RETURN_DYNAMIC \
    "system" \
    "system/framework/framework.jar" \
    "com/samsung/android/globalactions/util/SystemPropertiesWrapper.smali" \
    "isBrazilianCountryISO()Z" \
    "true"

PATCH_CSC_RETURN_DYNAMIC \
    "system_ext" \
    "priv-app/SystemUI/SystemUI.apk" \
    "com/android/systemui/bixby2/controller/DeviceController.smali" \
    "isSupportPowerOffLock()Z" \
    "true"

# Hide Remote Support from its One UI 9 XML preference.
SECSETTINGS_APK="system/priv-app/SecSettings/SecSettings.apk"

DECODE_APK \
    "system" \
    "$SECSETTINGS_APK" \
    || ABORT "Failed to decode SecSettings.apk"

SECSETTINGS_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

LOG "- Removing Remote Support from meta_009_settings.xml"

python3 \
    "$MODPATH/patch_remote_support_xml.py" \
    "$SECSETTINGS_DIR" \
    || ABORT "Failed to remove Remote Support XML preference"

LOG "- Remote Support XML removal fully validated"

unset SECSETTINGS_APK
unset SECSETTINGS_DIR
unset -f PATCH_CSC_RETURN_DYNAMIC

# BEGIN ONEUI9 NETWORK SPEED PATCH
NETWORK_SPEED_APK="system/priv-app/SecSettings/SecSettings.apk"

DECODE_APK \
    "system" \
    "$NETWORK_SPEED_APK" \
    || ABORT "Failed to decode SecSettings.apk for network speed patch"

NETWORK_SPEED_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

LOG "- Enabling real-time network speed semantically"

python3 \
    "$MODPATH/patch_network_speed_oneui9.py" \
    "$NETWORK_SPEED_DIR" \
    || ABORT "Real-time network speed patch is incomplete"

LOG "- Real-time network speed patch fully validated"

unset NETWORK_SPEED_APK
unset NETWORK_SPEED_DIR
# END ONEUI9 NETWORK SPEED PATCH

# BEGIN ONEUI9 POWER OFF LOCK SETTINGS PATCH
POWER_OFF_LOCK_APK="system/priv-app/SecSettings/SecSettings.apk"
POWER_OFF_LOCK_TEMPLATE="$MODPATH/smali/system/priv-app/SecSettings/SecSettings.apk/0002-Enable-Power-off-lock-feature.patch.disabled-oneui9"

DECODE_APK \
    "system" \
    "$POWER_OFF_LOCK_APK" \
    || ABORT "Failed to decode SecSettings.apk for Power Off Lock"

POWER_OFF_LOCK_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

LOG "- Enabling Power Off Lock in SecSettings semantically"

python3 \
    "$MODPATH/patch_poweroff_lock_oneui9.py" \
    "$POWER_OFF_LOCK_DIR" \
    "$POWER_OFF_LOCK_TEMPLATE" \
    || ABORT "Power Off Lock SecSettings patch is incomplete"

LOG "- Power Off Lock SecSettings patch fully validated"

unset POWER_OFF_LOCK_APK
unset POWER_OFF_LOCK_TEMPLATE
unset POWER_OFF_LOCK_DIR
# END ONEUI9 POWER OFF LOCK SETTINGS PATCH

# BEGIN ONEUI9 SECURE FOLDER QUICK SWITCH
SECURE_FOLDER_APK="system/priv-app/SecSettings/SecSettings.apk"

DECODE_APK \
    "system" \
    "$SECURE_FOLDER_APK" \
    || ABORT "Failed to decode SecSettings.apk for Secure Folder quick switch"

SECURE_FOLDER_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

LOG "- Enabling quick switch to Secure Folder semantically"

python3 \
    "$MODPATH/patch_secure_folder_quick_switch_oneui9.py" \
    "$SECURE_FOLDER_DIR" \
    || ABORT "Secure Folder quick switch patch is incomplete"

LOG "- Secure Folder quick switch patch fully validated"

unset SECURE_FOLDER_APK
unset SECURE_FOLDER_DIR
# END ONEUI9 SECURE FOLDER QUICK SWITCH
