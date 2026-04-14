-module(gleepack_zip_ffi).
-export([build_memory/1, open/1, close/1, list_files/1, get_file/2,
         extract_to_disk/2]).

-include_lib("stdlib/include/zip.hrl").
-include_lib("kernel/include/file.hrl").

%% Build a zip archive in memory from a Builder record.
%%
%% The Builder Gleam type is {builder, Files, StoredExtensions} where:
%%   Files = [{Path, Data}]  (in reverse-insertion order)
%%   StoredExtensions = [<<".beam">>, ...]
%%
%% Files with a stored extension are written uncompressed; all others use
%% deflate. An empty StoredExtensions list means compress everything.
build_memory({builder, Files, StoredExts}) ->
    Entries = [{unicode:characters_to_list(P), D} || {P, D} <- lists:reverse(Files)],
    Opts = [memory | uncompress_opt(StoredExts)],
    {ok, {_, Data}} = zip:create(<<"archive.zip">>, Entries, Opts),
    Data.

uncompress_opt([]) ->
    [];
uncompress_opt(Exts) ->
    [{uncompress, [unicode:characters_to_list(E) || E <- Exts]}].

%% Open a zip archive from bytes for reading.
open(Zip) ->
    case zip:zip_open(Zip, [memory]) of
        {ok, Handle} -> {ok, Handle};
        {error, _}   -> {error, invalid_archive}
    end.

%% Close an open zip handle.
close(Handle) ->
    _ = zip:zip_close(Handle),
    nil.

%% List all file entries in an open zip archive.
list_files(Handle) ->
    case is_alive(Handle) of
        false ->
            {error, handle_closed};
        true ->
            case zip:zip_list_dir(Handle) of
                {ok, [#zip_comment{} | Files]} ->
                    {ok, [to_entry(F) || F <- Files]};
                {error, _} ->
                    {error, handle_closed}
            end
    end.

%% Read a single file from an open zip archive by path.
get_file(Handle, Path) ->
    case is_alive(Handle) of
        false ->
            {error, handle_closed};
        true ->
            Name = unicode:characters_to_list(Path),
            case zip:zip_get(Name, Handle) of
                {ok, {_, Data}}        -> {ok, Data};
                {error, file_not_found} -> {error, {file_missing, Path}};
                {error, _}             -> {error, handle_closed}
            end
    end.

%% Extract all files from a zip binary to a directory on disk.
extract_to_disk(Zip, Dir) ->
    DirStr = unicode:characters_to_list(Dir),
    case zip:extract(Zip, [{cwd, DirStr}]) of
        {ok, Files} ->
            {ok, [unicode:characters_to_binary(F) || F <- Files]};
        {error, _} ->
            {error, invalid_archive}
    end.

%% --- internal helpers --------------------------------------------------------

is_alive(Handle) ->
    erlang:is_process_alive(Handle).

%% Convert a #zip_file{} record to a Gleam Entry tuple: {entry, Path, Size}.
to_entry(#zip_file{name = Name, info = #file_info{size = Size}}) ->
    {entry, unicode:characters_to_binary(Name), Size}.
