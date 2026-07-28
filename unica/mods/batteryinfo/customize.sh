# Show Samsung battery health/manufacture/cycle info outside Samsung's
# model/region allowlist.

SECSETTINGS_APK="system/priv-app/SecSettings/SecSettings.apk"
BATTERY_CLASS="com/samsung/android/settings/deviceinfo/batteryinfo/BatteryRegulatoryPreferenceController.smali"

DECODE_APK \
    "system" \
    "$SECSETTINGS_APK" \
    || ABORT "Failed to decode SecSettings.apk"

SECSETTINGS_DIR="$APKTOOL_DIR/$SECSETTINGS_APK"

BATTERY_SMALI_ABS="$(
    find "$SECSETTINGS_DIR" \
        -type f \
        -path "*/$BATTERY_CLASS" \
        -print \
        -quit
)"

if [ -z "$BATTERY_SMALI_ABS" ]; then
    ABORT "BatteryRegulatoryPreferenceController.smali not found in SecSettings.apk"
fi

BATTERY_SMALI="${BATTERY_SMALI_ABS#"$SECSETTINGS_DIR"/}"

if ! grep -q \
        '^\.method.*getAvailabilityStatus()I' \
        "$BATTERY_SMALI_ABS"; then
    ABORT "getAvailabilityStatus()I not found in $BATTERY_SMALI"
fi

LOG "- Enabling Battery Health/Cycle info using $BATTERY_SMALI"

SMALI_PATCH \
    "system" \
    "$SECSETTINGS_APK" \
    "$BATTERY_SMALI" \
    "return" \
    'getAvailabilityStatus()I' \
    '0' \
    || ABORT "Failed to enable Battery Health/Cycle info"

unset SECSETTINGS_APK
unset SECSETTINGS_DIR
unset BATTERY_CLASS
unset BATTERY_SMALI_ABS
unset BATTERY_SMALI
