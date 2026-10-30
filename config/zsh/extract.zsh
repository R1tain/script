# ============================================================
# Universal archive extraction
# ============================================================

extract() {
    if [[ $# -ne 1 ]]; then
        print "用法：extract <压缩文件>"
        return 2
    fi

    local archive="$1"

    if [[ ! -f "$archive" ]]; then
        print "extract: 文件不存在：$archive"
        return 1
    fi

    case "$archive" in

        *.tar.gz|*.tgz)
            command tar -xzf "$archive"
            ;;

        *.tar.bz2|*.tbz|*.tbz2)
            command tar -xjf "$archive"
            ;;

        *.tar.xz|*.txz)
            command tar -xJf "$archive"
            ;;

        *.tar.zst|*.tzst)
            command tar --zstd -xf "$archive"
            ;;

        *.tar)
            command tar -xf "$archive"
            ;;

        *.zip)
            command unzip "$archive"
            ;;

        *.7z)
            if command -v 7z >/dev/null 2>&1; then
                command 7z x "$archive"
            elif command -v 7zz >/dev/null 2>&1; then
                command 7zz x "$archive"
            else
                print "extract: 未安装 7z / 7zz"
                return 1
            fi
            ;;

        *.rar)
            if command -v 7z >/dev/null 2>&1; then
                command 7z x "$archive"
            elif command -v 7zz >/dev/null 2>&1; then
                command 7zz x "$archive"
            elif command -v unrar >/dev/null 2>&1; then
                command unrar x "$archive"
            else
                print "extract: 未安装 unrar / 7z / 7zz"
                return 1
            fi
            ;;

        *.gz)
            local target="${archive%.gz}"
            [[ ! -e "$target" ]] || { print "extract: 目标已存在，跳过：$target"; return 1; }
            command gunzip -k "$archive"
            ;;

        *.bz2)
            local target="${archive%.bz2}"
            [[ ! -e "$target" ]] || { print "extract: 目标已存在，跳过：$target"; return 1; }
            command bunzip2 -k "$archive"
            ;;

        *.xz)
            local target="${archive%.xz}"
            [[ ! -e "$target" ]] || { print "extract: 目标已存在，跳过：$target"; return 1; }
            command unxz -k "$archive"
            ;;

        *.zst)
            local target="${archive%.zst}"
            [[ ! -e "$target" ]] || { print "extract: 目标已存在，跳过：$target"; return 1; }
            command unzstd -k "$archive"
            ;;

        *)
            print "extract: 不支持的压缩格式：$archive"
            return 1
            ;;

    esac
}
