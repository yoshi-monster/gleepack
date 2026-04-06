%% Minimal hello world application for testing the gleepack pipeline.
%% Prints a message and exits with code 0.
-module(hello_world).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Pid = spawn_link(fun main/0),
    {ok, Pid}.

main() ->
    application:ensure_all_started(ssl),
    application:ensure_all_started(inets),
    Start = erlang:monotonic_time(millisecond),
    io:format("Hello, World!~n"),
    erlang:display(
        httpc:request("https://gleam.run")),

    End = erlang:monotonic_time(millisecond),
    erlang:display(End - Start),
    erlang:halt(0).

stop(_State) ->
    ok.
