#!/bin/sh
# Installs or removes the MicBridge Microphone driver.
#
#   install-driver.sh install <path to MicBridgeMicrophone.driver>
#   install-driver.sh uninstall
#
# Run as root. The MicBridge app runs it only after the user has confirmed,
# through macOS's administrator prompt (the user types the password). By
# hand: sudo /bin/sh install-driver.sh install MicBridge.app/Contents/PlugIns/MicBridgeMicrophone.driver
#
# Installing copies the bundle into /Library/Audio/Plug-Ins/HAL (replacing
# an older copy in one step) and restarts coreaudiod, which loads it. Sound
# on this Mac stops for a few seconds while it restarts.
#
# Test options, refused when running as root:
#   --dest DIR      use DIR instead of /Library/Audio/Plug-Ins/HAL
#   --no-restart    leave coreaudiod alone
set -eu

NAME=MicBridgeMicrophone.driver
DEST=/Library/Audio/Plug-Ins/HAL
RESTART=1

usage() {
    echo "usage: install-driver.sh install <$NAME> | uninstall" >&2
    exit 64
}

ACTION=${1:-}
if [ $# -gt 0 ]; then shift; fi
SOURCE=
if [ "$ACTION" = install ]; then
    [ $# -gt 0 ] || usage
    SOURCE=$1
    shift
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)
            if [ "$(id -u)" -eq 0 ]; then echo "--dest is for tests and is not allowed as root" >&2; exit 64; fi
            [ $# -ge 2 ] || usage
            DEST=$2
            shift 2
            ;;
        --no-restart)
            if [ "$(id -u)" -eq 0 ]; then echo "--no-restart is for tests and is not allowed as root" >&2; exit 64; fi
            RESTART=0
            shift
            ;;
        *) usage ;;
    esac
done

restart_audio() {
    [ "$RESTART" = 1 ] || return 0
    launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
}

case "$ACTION" in
    install)
        SOURCE=${SOURCE%/}
        if [ "$(basename "$SOURCE")" != "$NAME" ] || [ ! -f "$SOURCE/Contents/Info.plist" ]; then
            echo "not a $NAME bundle: $SOURCE" >&2
            exit 65
        fi
        if ! codesign --verify --strict "$SOURCE"; then
            echo "the driver's signature is not valid: $SOURCE" >&2
            exit 66
        fi
        mkdir -p "$DEST"
        STAGING="$DEST/.$NAME.installing"
        OLD="$DEST/.$NAME.old"
        rm -rf "$STAGING" "$OLD"
        ditto "$SOURCE" "$STAGING"
        if [ "$(id -u)" -eq 0 ]; then
            chown -R root:wheel "$STAGING"
            chmod -R go-w "$STAGING"
        fi
        if [ -e "$DEST/$NAME" ]; then mv "$DEST/$NAME" "$OLD"; fi
        mv "$STAGING" "$DEST/$NAME"
        rm -rf "$OLD"
        restart_audio
        echo "installed $DEST/$NAME"
        ;;
    uninstall)
        if [ -e "$DEST/$NAME" ]; then
            rm -rf "$DEST/$NAME"
            restart_audio
            echo "removed $DEST/$NAME"
        else
            echo "not installed"
        fi
        ;;
    *) usage ;;
esac
