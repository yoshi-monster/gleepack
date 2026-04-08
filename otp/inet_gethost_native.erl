%% Drop-in replacement for inet_gethost_native that uses net:getaddrinfo/getnameinfo
-module(inet_gethost_native).
-moduledoc false.
-behaviour(supervisor_bridge).

%% Supervisor bridge exports
-export([start_link/0, init/1, terminate/2]).

%% Server export
-export([server_init/2, main_loop/1]).

%% API exports
-export([gethostbyname/1, gethostbyname/2, gethostbyaddr/1, control/1]).

%% sys callbacks
-export([system_continue/3, system_terminate/4, system_code_change/4]).

-include_lib("kernel/include/inet.hrl").

-define(PROCNAME_SUP, inet_gethost_native_sup).

%%-----------------------------------------------------------------------
%% Supervisor bridge
%%-----------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor_bridge:start_link({local, ?PROCNAME_SUP}, ?MODULE, []).

-spec init([]) -> {ok, pid(), pid()} | {error, term()}.
init([]) ->
    Pid = proc_lib:start_link(?MODULE, server_init, [self(), []]),
    {ok, Pid, Pid}.

-spec terminate(term(), pid()) -> ok.
terminate(_Reason, Pid) ->
    Pid ! stop,
    ok.

%%-----------------------------------------------------------------------
%% Server (kept for interface parity — no port, no pool)
%%-----------------------------------------------------------------------

server_init(Starter, _Args) ->
    case (catch register(?MODULE, self())) of
        true ->
            proc_lib:init_ack(Starter, {ok, self()});
        _ ->
            proc_lib:init_ack(Starter, {error, {already_started, whereis(?MODULE)}})
    end,
    receive stop -> ok end.

main_loop(_State) ->
    receive stop -> ok end.

%%-----------------------------------------------------------------------
%% sys callbacks
%%-----------------------------------------------------------------------

system_continue(_Parent, _Debug, State) ->
    main_loop(State).

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

-spec system_code_change(term(), module(), term(), term()) -> {ok, term()}.
system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------------
%% Public API
%%-----------------------------------------------------------------------

%% Forward lookup: name to address(es).
-spec gethostbyname(inet:hostname()) ->
    {ok, inet:hostent()} | {error, inet:posix() | term()}.
gethostbyname(Name) ->
    gethostbyname(Name, inet).

-spec gethostbyname(inet:hostname(), inet | inet6) ->
    {ok, inet:hostent()} | {error, inet:posix() | term()}.
gethostbyname(Name, inet) when is_list(Name) ->
    case net:getaddrinfo(Name) of
        {ok, Infos} ->
            Addrs = [maps:get(addr, maps:get(address, Entry))
                     || Entry <- Infos,
                        maps:get(family, maps:get(address, Entry)) =:= inet],
            case Addrs of
                [] -> {error, nxdomain};
                _  ->
                    {ok, #hostent{
                        h_name      = Name,
                        h_aliases   = [],
                        h_addrtype  = inet,
                        h_length    = 4,
                        h_addr_list = Addrs}}
            end;
        {error, _} ->
            {error, nxdomain}
    end;
gethostbyname(Name, inet6) when is_list(Name) ->
    case net:getaddrinfo(Name) of
        {ok, Infos} ->
            Addrs = [maps:get(addr, maps:get(address, Entry))
                     || Entry <- Infos,
                        maps:get(family, maps:get(address, Entry)) =:= inet6],
            case Addrs of
                [] -> {error, nxdomain};
                _  ->
                    {ok, #hostent{
                        h_name      = Name,
                        h_aliases   = [],
                        h_addrtype  = inet6,
                        h_length    = 16,
                        h_addr_list = Addrs}}
            end;
        {error, _} ->
            {error, nxdomain}
    end;
gethostbyname(Name, Type) when is_atom(Name) ->
    gethostbyname(atom_to_list(Name), Type);
gethostbyname(_, _) ->
    {error, formerr}.

%% Reverse lookup: address to name.
-spec gethostbyaddr(inet:ip_address() | string() | atom()) ->
    {ok, inet:hostent()} | {error, inet:posix() | term()}.
gethostbyaddr({A,B,C,D} = Addr)
  when is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    case net:getnameinfo(#{family => inet, addr => Addr, port => 0}) of
        {ok, #{host := Host}} ->
            {ok, #hostent{
                h_name      = Host,
                h_aliases   = [],
                h_addrtype  = inet,
                h_length    = 4,
                h_addr_list = [Addr]}};
        {error, _} ->
            {error, nxdomain}
    end;
gethostbyaddr({A,B,C,D,E,F,G,H} = Addr)
  when is_integer(A), is_integer(B), is_integer(C), is_integer(D),
       is_integer(E), is_integer(F), is_integer(G), is_integer(H) ->
    case net:getnameinfo(#{family => inet6, addr => Addr, port => 0}) of
        {ok, #{host := Host}} ->
            {ok, #hostent{
                h_name      = Host,
                h_aliases   = [],
                h_addrtype  = inet6,
                h_length    = 16,
                h_addr_list = [Addr]}};
        {error, _} ->
            {error, nxdomain}
    end;
gethostbyaddr(Addr) when is_list(Addr) ->
    case inet_parse:address(Addr) of
        {ok, IP} -> gethostbyaddr(IP);
        _Error   -> {error, formerr}
    end;
gethostbyaddr(Addr) when is_atom(Addr) ->
    gethostbyaddr(atom_to_list(Addr));
gethostbyaddr(_) ->
    {error, formerr}.

%% Control: no-op — no port to configure or restart.
-spec control(term()) -> ok | {error, term()}.
control({debug_level, _Level}) when is_integer(_Level) ->
    ok;
control(soft_restart) ->
    ok;
control(_) ->
    {error, formerr}.
