# Sourced by the other scripts: select Xcode without touching xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    case "$(xcode-select -p 2>/dev/null)" in
        *.app/*) ;;
        *) export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
if [ ! -d "${DEVELOPER_DIR:-$(xcode-select -p)}" ]; then
    echo "Xcode not found at ${DEVELOPER_DIR:-$(xcode-select -p)}; set DEVELOPER_DIR to your Xcode.app/Contents/Developer" >&2
    return 1 2>/dev/null || exit 1
fi
