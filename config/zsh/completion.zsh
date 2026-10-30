# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------

# zsh-completions must be added before compinit.
if [[ -d "${HOME}/.local/share/zsh/plugins/zsh-completions/src" ]]; then
    fpath=("${HOME}/.local/share/zsh/plugins/zsh-completions/src" $fpath)
fi

autoload -Uz compinit

# Only rebuild the completion cache once every 24h instead of on
# every shell start; falls back to a full compinit the first time
# or if the dump file is missing/stale.
_zcompdump="${ZDOTDIR:-${HOME}}/.zcompdump"
if [[ -n "${_zcompdump}"(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi
unset _zcompdump

