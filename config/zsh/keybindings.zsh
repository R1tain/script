# ------------------------------------------------------------
# Keypad
# ------------------------------------------------------------

# ZLE sends smkx to enable application keypad mode, but zsh leaves
# these application-mode sequences unbound by default.
if [[ -o interactive ]]; then
    bindkey -s '^[Op' '0'
    bindkey -s '^[Oq' '1'
    bindkey -s '^[Or' '2'
    bindkey -s '^[Os' '3'
    bindkey -s '^[Ot' '4'
    bindkey -s '^[Ou' '5'
    bindkey -s '^[Ov' '6'
    bindkey -s '^[Ow' '7'
    bindkey -s '^[Ox' '8'
    bindkey -s '^[Oy' '9'
    bindkey -s '^[OE' '5'
    bindkey -s '^[Oj' '*'
    bindkey -s '^[Ok' '+'
    bindkey -s '^[Ol' ','
    bindkey -s '^[Om' '-'
    bindkey -s '^[On' '.'
    bindkey -s '^[Oo' '/'
    bindkey '^[OM' accept-line

    _zsh_bind_navigation() {
        local seq="${1}" widget="${2}" vi_widget="${3:-${2}}"
        [[ -n "${seq}" ]] || return 0
        bindkey -M emacs "${seq}" "${widget}"
        bindkey -M viins "${seq}" "${vi_widget}"
        bindkey -M vicmd "${seq}" "${vi_widget}"
    }

    # Common terminal sequences; terminfo bindings below take precedence.
    _zsh_bind_navigation '^[OH' beginning-of-line vi-beginning-of-line
    _zsh_bind_navigation '^[OF' end-of-line vi-end-of-line
    _zsh_bind_navigation '^[[H' beginning-of-line vi-beginning-of-line
    _zsh_bind_navigation '^[[F' end-of-line vi-end-of-line
    _zsh_bind_navigation '^[[1~' beginning-of-line vi-beginning-of-line
    _zsh_bind_navigation '^[[4~' end-of-line vi-end-of-line
    _zsh_bind_navigation '^[[2~' overwrite-mode
    _zsh_bind_navigation '^[[3~' delete-char
    _zsh_bind_navigation '^[[5~' up-line-or-history
    _zsh_bind_navigation '^[[6~' down-line-or-history
    _zsh_bind_navigation '^[[7~' beginning-of-line vi-beginning-of-line
    _zsh_bind_navigation '^[[8~' end-of-line vi-end-of-line

    zmodload zsh/terminfo
    _zsh_bind_navigation "${terminfo[khome]}" beginning-of-line vi-beginning-of-line
    _zsh_bind_navigation "${terminfo[kend]}" end-of-line vi-end-of-line
    _zsh_bind_navigation "${terminfo[kich1]}" overwrite-mode
    _zsh_bind_navigation "${terminfo[kdch1]}" delete-char
    _zsh_bind_navigation "${terminfo[kpp]}" up-line-or-history
    _zsh_bind_navigation "${terminfo[knp]}" down-line-or-history
    unfunction _zsh_bind_navigation
fi

