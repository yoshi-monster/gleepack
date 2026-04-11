%% Drop-in replacement for inet_gethost_native that uses net:getaddrinfo/getnameinfo.
%% No port or server process is needed — lookups are performed inline.
-module(inet_gethost_native).
-moduledoc false.

-export([start_link/0]).
-export([gethostbyname/1, gethostbyname/2, gethostbyaddr/1, control/1]).

-include_lib("kernel/include/inet.hrl").

%% No server process needed — tell the kernel supervisor to skip us.
start_link() ->
    ignore.

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
            Addrs = [maps:get(addr, maps:get(addr, Entry))
                     || Entry <- Infos,
                        maps:get(family, Entry) =:= inet],
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
            Addrs = [maps:get(addr, maps:get(addr, Entry))
                     || Entry <- Infos,
                        maps:get(family, Entry) =:= inet6],
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
