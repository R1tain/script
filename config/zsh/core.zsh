
# ============================================================
# Zsh Server Environment
# Managed by zsh-manager
# ============================================================

export STARSHIP_CONFIG="${HOME}/.config/starship.toml"
export PATH="${HOME}/.local/bin:${PATH}"
if [[ "${TERM:-}" == "xterm" ]]; then
    unset COLORTERM
fi

# ------------------------------------------------------------
# History
# ------------------------------------------------------------

HISTFILE="${HOME}/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY

# ------------------------------------------------------------
# Navigation
# ------------------------------------------------------------

setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS

