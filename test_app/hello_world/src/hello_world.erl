%% Minimal hello world application for testing the gleepack pipeline.
%% Prints a message and exits with code 0.
-module(hello_world).

-behaviour(application).

-export([main/0, main/1, start/2, stop/1]).

start(_Type, _Args) ->
    Pid = spawn_link(fun main/0),
    {ok, Pid}.

main(_) -> main().

main() ->
    io:put_chars("Hello, world\n"),
    application:ensure_all_started([inets, ssl]),
    % inet_db:start_link(),
    erlang:display(inet:gethostbyname("gleam.run", inet)),
    {ok, {_, _, Body}} = httpc:request("https://gleam.run"),
    io:put_chars(Body),
    erlang:halt(0).

stop(_State) ->
    ok.
