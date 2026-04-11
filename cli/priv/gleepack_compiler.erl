-module(gleepack_compiler).

-export([main/1, main/0]).

main() ->
    [_Script | Args] = init:get_plain_arguments(),
    main(Args).

main([Lib]) ->
    ok = io:setopts([binary, {encoding, unicode}]),
    {ok, _} = application:ensure_all_started([compiler, elixir]),
    [code:add_patha(P) || P <- filelib:wildcard([Lib, "/*/ebin"])],
    Parent = self(),
    NumWorkers = erlang:system_info(schedulers),
    lists:foreach(fun(_) -> erlang:spawn_link(fun() -> worker_loop(Parent) end) end,
                  lists:seq(1, NumWorkers)),
    erlang:spawn_link(fun() -> reader_loop(Parent) end),
    dispatcher_loop(0).

% Reads stdin lines and forwards them to the main process so that the main
% loop can interleave dispatching work and collecting results in parallel.
reader_loop(Dispatcher) ->
    case io:get_line("") of
        eof ->
            Dispatcher ! eof;
        Line ->
            Dispatcher ! Line,
            reader_loop(Dispatcher)
    end.

% Pending = number of modules dispatched but not yet output a result for.
dispatcher_loop(Pending) ->
    receive
        {compiled, Module, Modules} ->
            io:put_chars(["gleepack-compile-ok ", format_result(Module, Modules), "\n"]),
            dispatcher_loop(Pending - 1);
        {failed, Module} ->
            io:put_chars(["gleepack-compile-error ", format_result(Module, []), "\n"]),
            dispatcher_loop(Pending - 1);
        eof ->
            drain(Pending);
        Line when is_binary(Line); is_list(Line) ->
            Chars = unicode:characters_to_list(Line),
            {ok, Tokens, _} = erl_scan:string(Chars),
            {ok, {Out, Module}} = erl_parse:parse_term(Tokens),
            % Selective receive: only blocks if all workers are busy, leaving
            % compiled/failed/line/eof messages untouched in the mailbox.
            %
            % This is fine since queuing other new files faster in response to
            % an "ok" messages wouldn't help, we're already blocked here!
            receive
                {work_please, Worker} ->
                    Worker ! {module, Module, Out}
            end,
            dispatcher_loop(Pending + 1)
    end.

drain(0) ->
    ok;
drain(Pending) ->
    receive
        {compiled, Module, Modules} ->
            io:put_chars(["gleepack-compile-ok ", format_result(Module, Modules), "\n"]),
            drain(Pending - 1);
        {failed, Module} ->
            io:put_chars(["gleepack-compile-error ", format_result(Module, []), "\n"]),
            drain(Pending - 1)
    end.

format_result(Module, Modules) ->
    io_lib:format("~0p.", [{Module, Modules}]).

worker_loop(Parent) ->
    Parent ! {work_please, self()},
    receive
        {module, Module, Out} ->
            Compile =
                case is_elixir_module(Module) of
                    true ->
                        compile_elixir(Module, Out);
                    false ->
                        compile_erlang(Module, Out)
                end,
            case Compile of
                {ok, Modules} ->
                    case strip(Out, Modules) of
                        ok ->
                            Parent ! {compiled, Module, Modules};
                        error ->
                            Parent ! {failed, Module}
                    end;
                error ->
                    Parent ! {failed, Module}
            end,
            worker_loop(Parent)
    end.

compile_erlang(Module, Out) ->
    Options =
        [no_spawn_compiler_process,
         report_errors,
         report_warnings,
         no_docs,
         {outdir, unicode:characters_to_list(Out)}],
    case compile:file(unicode:characters_to_list(Module), Options) of
        {ok, ModuleName} ->
            {ok, [ModuleName]};
        error ->
            error
    end.

compile_elixir(Module, Out) when is_list(Module) ->
    compile_elixir(list_to_binary(Module), Out);
compile_elixir(Module, Out) when is_list(Out) ->
    compile_elixir(Module, list_to_binary(Out));
compile_elixir(Module, Out) when is_binary(Module), is_binary(Out) ->
    Options = [{dest, Out}, {return_diagnostics, true}],
    % Silence "redefining module" warnings.
    % Compiled modules in the build directory are added to the code path.
    % These warnings result from recompiling loaded modules.
    % TODO: This line can likely be removed if/when the build directory is cleaned before every compilation.
    'Elixir.Code':compiler_options([{ignore_module_conflict, true}]),
    case 'Elixir.Kernel.ParallelCompiler':compile_to_path([Module], Out, Options) of
        {ok, ModuleAtoms, _} ->
            {ok, ModuleAtoms};
        _ ->
            error
    end.

strip(_Out, []) ->
    ok;
strip(Out, [ModuleName | Modules]) ->
    BeamFile = filename:join(Out, [atom_to_list(ModuleName), ".beam"]),
    case beam_lib:strip(BeamFile) of
        {ok, _} ->
            strip(Out, Modules);
        {error, _} ->
            error
    end.

is_elixir_module(Module) ->
    filename:extension(Module) =:= ".ex".
