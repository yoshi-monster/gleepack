-module(gleepack_ffi).

-export([version/1]).

version(Application) ->
    ApplicationAtom = binary_to_existing_atom(Application),
    {ok, Version} = application:get_key(ApplicationAtom, vsn),
    list_to_binary(Version).
