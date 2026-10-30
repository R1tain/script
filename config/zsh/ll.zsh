# ============================================================
# ll - grouped directory listing
# Order: hidden files -> hidden dirs -> files -> dirs
# Directory names stay uncolored because Xshell renders their foreground with an unreadable background.
# ============================================================

alias ls='ls --color=auto'

# 256-color file colors. GNU ls accepts SGR sequences in LS_COLORS.
export LS_COLORS="no=00:fi=00;38;5;@FILE_256@:di=00;38;5;@DIRECTORY_256@:ln=00;38;5;@LINK_256@:pi=00;38;5;@BUILTIN_256@:so=00;38;5;@GIT_256@:do=00;38;5;@GIT_256@:bd=00;38;5;@FUNCTION_256@:cd=00;38;5;@FUNCTION_256@:or=00;38;5;@ERROR_256@:mi=00;38;5;@ERROR_256@:su=00;38;5;@ERROR_256@:sg=00;38;5;@OPTION_256@:ca=00;38;5;@OPTION_256@:tw=00:ow=00:st=00:ex=00;38;5;@EXECUTABLE_256@:*.tar=00;38;5;@ARCHIVE_256@:*.tgz=00;38;5;@ARCHIVE_256@:*.gz=00;38;5;@ARCHIVE_256@:*.bz2=00;38;5;@ARCHIVE_256@:*.xz=00;38;5;@ARCHIVE_256@:*.zst=00;38;5;@ARCHIVE_256@:*.zip=00;38;5;@ARCHIVE_256@:*.7z=00;38;5;@ARCHIVE_256@:*.rar=00;38;5;@ARCHIVE_256@:*.deb=00;38;5;@ARCHIVE_256@:*.rpm=00;38;5;@ARCHIVE_256@"

ll() {
    emulate -L zsh
    setopt local_options null_glob

    local dir="${1:-.}"

    if [[ ! -d "$dir" ]]; then
        command ls -lAh --color=auto -- "$dir"
        return
    fi

    (
        cd -- "$dir" || return 1

        local -a hidden_dirs normal_dirs hidden_files normal_files
        hidden_dirs=(.*(N/))
        normal_dirs=(*(N/))
        hidden_files=(.*(N^/))
        normal_files=(*(N^/))

        local grey=$'\033[49m\033[38;5;@MUTED_256@m'
        local reset=$'\033[0m'

        if (( ${#hidden_files} )); then
            print "${grey}-- Hidden Files --${reset}"
            command ls -lhd --color=auto -- "${hidden_files[@]}"
        fi

        if (( ${#hidden_dirs} )); then
            print "${grey}-- Hidden Dirs --${reset}"
            command ls -lhd --color=auto -- "${hidden_dirs[@]}"
        fi

        if (( ${#normal_files} )); then
            print "${grey}-- Files --${reset}"
            command ls -lhd --color=auto -- "${normal_files[@]}"
        fi

        if (( ${#normal_dirs} )); then
            print "${grey}-- Dirs --${reset}"
            command ls -lhd --color=auto -- "${normal_dirs[@]}"
        fi
    )
}
