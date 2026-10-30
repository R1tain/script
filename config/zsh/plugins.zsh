# Autosuggestion text stays readable while remaining visually secondary.
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=@SUGGESTION@'
if [[ -f "${HOME}/.local/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
    source "${HOME}/.local/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# Keep ZLE selections and pasted text on the terminal's existing background.
zle_highlight=(paste:none region:none special:none isearch:none)

# Syntax highlighting uses foreground colors only.
typeset -gA ZSH_HIGHLIGHT_STYLES

ZSH_HIGHLIGHT_STYLES[default]='fg=@TEXT@'
ZSH_HIGHLIGHT_STYLES[root]='none'
ZSH_HIGHLIGHT_STYLES[cursor]='none'
ZSH_HIGHLIGHT_STYLES[cursor-matchingbracket]='none'
ZSH_HIGHLIGHT_STYLES[arg0]='fg=@COMMAND@'
ZSH_HIGHLIGHT_STYLES[command]='fg=@VALID_COMMAND@'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=@BUILTIN@'
ZSH_HIGHLIGHT_STYLES[alias]='fg=@BUILTIN@'
ZSH_HIGHLIGHT_STYLES[function]='fg=@FUNCTION@'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=@COMMAND@'
ZSH_HIGHLIGHT_STYLES[autodirectory]='fg=@BUILTIN@'
ZSH_HIGHLIGHT_STYLES[suffix-alias]='fg=@COMMAND@'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=@GIT@'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=@ERROR@'
ZSH_HIGHLIGHT_STYLES[commandseparator]='fg=@MUTED@'
ZSH_HIGHLIGHT_STYLES[redirection]='fg=@LINK@'
ZSH_HIGHLIGHT_STYLES[path]='fg=@TEXT@'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=@GIT@'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=@OPTION@'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=@OPTION@'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=@VALID_COMMAND@'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=@VALID_COMMAND@'
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]='fg=@VALID_COMMAND@'
ZSH_HIGHLIGHT_STYLES[comment]='fg=@MUTED@,italic'
ZSH_HIGHLIGHT_STYLES[history-expansion]='fg=@GIT@'
ZSH_HIGHLIGHT_STYLES[bracket-error]='fg=@ERROR@'
ZSH_HIGHLIGHT_STYLES[bracket-level-1]='fg=@FUNCTION@'
ZSH_HIGHLIGHT_STYLES[bracket-level-2]='fg=@VALID_COMMAND@'
ZSH_HIGHLIGHT_STYLES[bracket-level-3]='fg=@GIT@'
ZSH_HIGHLIGHT_STYLES[bracket-level-4]='fg=@COMMAND@'
ZSH_HIGHLIGHT_STYLES[bracket-level-5]='fg=@BUILTIN@'

if [[ -f "${HOME}/.local/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
    source "${HOME}/.local/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
