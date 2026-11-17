# Von den anderen Skripten eingebunden: Xcode wählen, ohne xcode-select zu ändern.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    case "$(xcode-select -p 2>/dev/null)" in
        *.app/*) ;;
        *) export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
if [ ! -d "${DEVELOPER_DIR:-$(xcode-select -p)}" ]; then
    echo "Xcode nicht gefunden unter ${DEVELOPER_DIR:-$(xcode-select -p)}; DEVELOPER_DIR auf Xcode.app/Contents/Developer setzen" >&2
    return 1 2>/dev/null || exit 1
fi
