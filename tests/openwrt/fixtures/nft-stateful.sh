#!/bin/sh
# Small stateful nft model for WARP production-path acceptance tests.
# The adapter calls nft directly; this models only the owned chains/sets and
# fw4 rule operations exercised by those real calls.
: "${T:?T must name the test sandbox}"
state="$T/nft-state"
mkdir -p "$state"
printf 'nft:%s\n' "$*" >> "$T/nft.log"

chain_file() { printf '%s/chain-%s' "$state" "$1"; }
set_file() { printf '%s/set-%s' "$state" "$1"; }

show_chain() {
    _file=$(chain_file "$1")
    [ -f "$_file" ] || return 1
    printf 'chain %s {\n' "$1"
    cat "$_file"
    printf '}\n'
}

append_rule() {
    _file=$(chain_file "$1")
    shift
    _line=
    _prev=
    for _arg in "$@"; do
        if [ "$_prev" = iifname ] || [ "$_prev" = oifname ]; then
            # Keep nft's argument quotes literal in this serialized rule text.
            # shellcheck disable=SC2089
            _line="$_line \"$_arg\""
        else
            _line="$_line $_arg"
        fi
        _prev="$_arg"
    done
    printf '%s\n' "$_line" >> "$_file"
}

apply_batch() {
    _batch="$T/nft-batch-in"
    cat > "$_batch" || return 1
    sed 's/^/nft-batch:/' "$_batch" >> "$T/nft.log"
    if [ -n "${NFT_BATCH_FAIL:-}" ] && grep -qF "$NFT_BATCH_FAIL" "$_batch"; then
        return 1
    fi
    while IFS= read -r _line; do
        # Intentional word splitting parses this fixture's serialized command.
        # shellcheck disable=SC2090
        set -- $_line
        case "$1 $2" in
            'add chain') : >> "$(chain_file "$5")" ;;
            'flush chain') : > "$(chain_file "$5")" ;;
            'add rule') _chain="$5"; shift 5; append_rule "$_chain" "$@" ;;
            'flush set') : > "$(set_file "$5")" ;;
            'add element')
                _set="$5"
                _elements=$(printf '%s\n' "$_line" | sed 's/^[^{}]*{//; s/}.*$//')
                printf '%s\n' "$_elements" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                    | while IFS= read -r _value; do [ -n "$_value" ] && printf '%s\n' "$_value" >> "$(set_file "$_set")"; done
                ;;
        esac
    done < "$_batch"
}

if [ "$1" = -f ] && [ "$2" = - ]; then
    apply_batch
    exit $?
fi

if [ "$1" = list ] && [ "$2" = table ]; then
    if [ "$4" = z2k_warp_dns ]; then [ -f "$T/nft-domain-table" ] || exit 1; cat "$T/nft-domain-table"; exit 0; fi
    [ -f "$T/no-table" ] && exit 1
    printf 'table %s %s {\n' "$3" "$4"
    for _file in "$state"/chain-*; do
        [ -f "$_file" ] || continue
        _name=${_file##*/chain-}
        printf ' chain %s { }\n' "$_name"
    done
    printf '}\n'
    exit 0
fi

if [ "$1" = list ] && [ "$2" = set ]; then
    _file=$(set_file "$5")
    [ -f "$_file" ] || exit 1
    _items=$(sed 's#/32$##' "$_file" | paste -sd ', ')
    if [ -n "$_items" ]; then
        printf 'set %s { type ipv4_addr; flags interval; elements = { %s } }\n' "$5" "$_items"
    else
        printf 'set %s { type ipv4_addr; flags interval; }\n' "$5"
    fi
    exit 0
fi

if [ "$1" = list ] && [ "$2" = chain ]; then
    if [ "$4" = fw4 ] && [ "$5" = forward ]; then
        [ -f "$T/fw4-forward" ] && cat "$T/fw4-forward"
        exit 0
    fi
    show_chain "$5"
    exit $?
fi

if [ "$1" = -a ] && [ "$2" = list ] && [ "$3" = chain ] && [ "$5" = fw4 ] && [ "$6" = forward ]; then
    [ -f "$T/fw4-forward" ] && cat "$T/fw4-forward"
    exit 0
fi

if [ "$1" = add ] && [ "$2" = set ]; then
    : >> "$(set_file "$5")"
    exit 0
fi

if [ "$1" = add ] && [ "$2" = chain ]; then
    : >> "$(chain_file "$5")"
    exit 0
fi

if [ "$1" = flush ] && [ "$2" = chain ]; then
    : > "$(chain_file "$5")"
    exit 0
fi

if [ "$1" = add ] && [ "$2" = rule ]; then
    _chain="$5"
    shift 5
    append_rule "$_chain" "$@"
    exit 0
fi

if [ "$1" = insert ] && [ "$2" = rule ] && [ "$4" = fw4 ] && [ "$5" = forward ]; then
    _prev=
    _iface=
    for _arg in "$@"; do
        [ "$_prev" = oifname ] && _iface="$_arg"
        _prev="$_arg"
    done
    printf 'meta mark & 0x80000000 == 0x80000000 oifname "%s" accept comment "!z2k: WARP forwarded traffic" # handle 91\n' \
        "$_iface" > "$T/fw4-forward"
    exit 0
fi

if [ "$1" = delete ] && [ "$2" = rule ] && [ "$4" = fw4 ] && [ "$5" = forward ]; then
    rm -f "$T/fw4-forward"
    exit 0
fi

exit 0
