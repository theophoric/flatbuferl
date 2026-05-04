Header "%% @private".

Nonterminals root definition option fields field key_def value attribute_def attributes atoms atom.
Terminals  table struct enum union namespace root_type include attribute file_identifier file_extension float int bool null string '}' '{' '(' ')' '[' ']' ';' ',' ':' '=' quote.
Rootsymbol root.

root -> definition      : {'$1', #{}}.
root -> option          : {#{}, '$1'}.
root -> root definition : add_def('$1', '$2').
root -> root option     : add_opt('$1', '$2').

% options (non-quoted)
option -> namespace string ';' : #{get_name('$1') => get_value_atom('$2')}.
option -> root_type string ';' : #{get_name('$1') => get_value_atom('$2')}.

% options (quoted)
option -> include quote string quote ';'         : #{include => [get_value_bin('$3')]}.
option -> attribute quote string quote ';'       : #{get_name('$1') => get_value_bin('$3')}.
option -> file_identifier quote string quote ';' : #{get_name('$1') => get_value_bin('$3')}.
option -> file_extension quote string quote ';'  : #{get_name('$1') => get_value_bin('$3')}.

% definitions
definition -> table string '{' fields '}'           : #{get_value_atom('$2') => {table, '$4'} }.
definition -> table string '{' '}'                  : #{get_value_atom('$2') => {table, []} }.
definition -> struct string '{' fields '}'          : #{get_value_atom('$2') => {struct, '$4'} }.
definition -> struct string '{' '}'                 : #{get_value_atom('$2') => {struct, []} }.
definition -> enum string ':' string '{' atoms '}'  : #{get_value_atom('$2') => {{enum, get_value_atom('$4')}, '$6' }}.
definition -> union string '{' atoms '}'            : #{get_value_atom('$2') => {union, '$4'} }.

% tables
fields -> field ';'         : [ '$1' ].
fields -> field ';' fields  : [ '$1' | '$3' ].

field -> key_def                    : add_attrs('$1', #{}).
field -> key_def '(' attributes ')' : add_attrs('$1', '$3').

key_def -> string ':' string              : { get_value_atom('$1'), get_value_atom('$3') }.
key_def -> string ':' '[' string ']'      : { get_value_atom('$1'), {vector, get_value_atom('$4')}}.
key_def -> string ':' '[' string ':' int ']' : { get_value_atom('$1'), {array, get_value_atom('$4'), get_value('$6')}}.
key_def -> string ':' string '=' value    : { get_value_atom('$1'), {get_value_atom('$3'), '$5' }}.

attributes -> attribute_def ',' attributes : maps:merge('$1', '$3').
attributes -> attribute_def                : '$1'.
attribute_def -> string ':' value          : #{ get_value_atom('$1') => '$3' }.
attribute_def -> string                    : #{ get_value_atom('$1') => true }.

value -> int      : get_value('$1').
value -> float    : get_value('$1').
value -> bool     : get_value('$1').
value -> null     : undefined.
value -> string   : get_value_bin('$1').
value -> quote string quote : get_value_bin('$2').

% enums + unions
atoms -> atom             : [ '$1' ].
atoms -> atom ',' atoms   : [ '$1' | '$3'].
atoms -> atom ','         : [ '$1' ].

atom -> string : get_value_atom('$1').
atom -> string '=' int : {get_value_atom('$1'), get_value('$3')}.  %% enum with explicit value

Erlang code.

get_value_atom({_Token, _Line, Value}) -> list_to_atom(Value).
get_value_bin({_Token, _Line, Value})  -> list_to_binary(Value).
get_value({_Token, _Line, Value})      -> Value.

get_name({Token, _Line, _Value})  -> Token;
get_name({Token, _Line})          -> Token.

add_def({Defs, Opts}, Def) -> {maps:merge(Defs, Def), Opts}.
add_opt({Defs, Opts}, #{include := NewIncludes}) ->
    %% Accumulate includes into a list
    Includes = maps:get(include, Opts, []),
    {Defs, Opts#{include => Includes ++ NewIncludes}};
add_opt({Defs, Opts}, Opt) -> {Defs, maps:merge(Opts, Opt)}.

add_attrs({Name, Type}, Attrs) when map_size(Attrs) == 0 -> {Name, Type};
add_attrs({Name, Type}, Attrs) -> {Name, Type, Attrs}.