-module(gleepack_eterm_ffi).

-export([charlist/1, prop/3, parse_term/1]).

%% Decode an Erlang charlist to a binary string.
charlist(Data) ->
    case io_lib:char_list(Data) of
        true ->
            {ok, list_to_binary(Data)};
        false ->
            {error, <<>>}
    end.

% This is all terrible. Compromise to unwrapping the decoder
% to at least get a zero value...
prop(Key, {decoder, Function}, Data) when is_list(Data) ->
    Atom = binary_to_atom(Key),
    case proplists:get_value(Atom, Data, '$gleepack_eterm_missing') of
        '$gleepack_eterm_missing' ->
            {Fallback, _} = Function(undefined),
            {error, Fallback};
        Value ->
            case Function(Value) of
                {Result, []} ->
                    {ok, Result};
                {Fallback, _} ->
                    {error, Fallback}
            end
    end;
prop(_, {decoder, Function}, _) ->
    {Fallback, _} = Function(undefined),
    {error, Fallback}.

%% Parse a single Erlang term from a string.
parse_term(String) ->
    case erl_scan:string(binary_to_list(String)) of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} ->
                    {ok, Term};
                {error, {_, Module, Desc}} ->
                    {error, list_to_binary(Module:format_error(Desc))}
            end;
        {error, {_, Module, Desc}, _} ->
            {error, list_to_binary(Module:format_error(Desc))}
    end.
