# Managed Zsh environment entry point.
# Keep initialization order stable: completion setup precedes plugins,
# syntax highlighting follows autosuggestions, and Starship initializes last.
typeset _zsh_config_dir="${HOME}/.config/zsh"
source "${_zsh_config_dir}/core.zsh"
source "${_zsh_config_dir}/keybindings.zsh"
source "${_zsh_config_dir}/completion.zsh"
source "${_zsh_config_dir}/plugins.zsh"
source "${_zsh_config_dir}/shell-tools.zsh"
source "${_zsh_config_dir}/prompt.zsh"
unset _zsh_config_dir
