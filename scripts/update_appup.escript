#!/usr/bin/env -S escript -c
%% -*- erlang-indent-level:4 -*-

usage() ->
"A script that fills in boilerplate for appup files.

Algorithm: this script compares md5s of beam files of each
application, and creates a `{load_module, Module, brutal_purge,
soft_purge, []}` action for the changed and new modules. For deleted
modules it creates `{delete_module, M}` action. These entries are
added to each patch release preceding the current release. If an entry
for a module already exists, this module is ignored. The existing
actions are kept.

Please note that it only compares the current release with its
predecessor, assuming that the upgrade actions for the older releases
are correct.

Note: The defaults are set up for emqx, but they can be tuned to
support other repos too.

Usage:

   update_appup.escript [--check] [--repo URL] [--remote NAME] [--skip-build] [--make-commad SCRIPT] [--release-dir DIR] <current_release_tag>

Options:

  --check         Don't update the appfile, just check that they are complete
  --prev-tag      Specify the previous release tag. Otherwise the previous patch version is used
  --repo          Upsteam git repo URL
  --remote        Get upstream repo URL from the specified git remote
  --skip-build    Don't rebuild the releases. May produce wrong results
  --make-command  A command used to assemble the release
  --release-dir   Release directory
  --src-dirs      Directories where source code is found. Defaults to '{src,apps,lib-*}/**/'
".

-record(app,
        { modules       :: #{module() => binary()}
        , version       :: string()
        }).

default_options() ->
    #{ clone_url    => find_upstream_repo("origin")
     , make_command => "make emqx-rel"
     , beams_dir    => "_build/emqx/rel/emqx/lib/"
     , check        => false
     , prev_tag     => undefined
     , src_dirs     => "{src,apps,lib-*}/**/"
     }.

main(Args) ->
    #{current_release := CurrentRelease} = Options = parse_args(Args, default_options()),
    init_globals(Options),
    case find_pred_tag(CurrentRelease) of
        {ok, Baseline} ->
            main(Options, Baseline);
        undefined ->
            log("No appup update is needed for this release, nothing to be done~n", []),
            ok
    end.

parse_args([CurrentRelease = [A|_]], State) when A =/= $- ->
    State#{current_release => CurrentRelease};
parse_args(["--check"|Rest], State) ->
    parse_args(Rest, State#{check => true});
parse_args(["--skip-build"|Rest], State) ->
    parse_args(Rest, State#{make_command => "true"});
parse_args(["--repo", Repo|Rest], State) ->
    parse_args(Rest, State#{clone_url => Repo});
parse_args(["--remote", Remote|Rest], State) ->
    parse_args(Rest, State#{clone_url => find_upstream_repo(Remote)});
parse_args(["--make-command", Command|Rest], State) ->
    parse_args(Rest, State#{make_command => Command});
parse_args(["--release-dir", Dir|Rest], State) ->
    parse_args(Rest, State#{beams_dir => Dir});
parse_args(_, _) ->
    fail(usage()).

main(Options, Baseline) ->
    {CurrRelDir, PredRelDir} = prepare(Baseline, Options),
    log("~n===================================~n"
        "Processing changes..."
        "~n===================================~n"),
    CurrAppsIdx = index_apps(CurrRelDir),
    PredAppsIdx = index_apps(PredRelDir),
    %% log("Curr: ~p~nPred: ~p~n", [CurrApps, PredApps]),
    AppupChanges = find_appup_actions(CurrAppsIdx, PredAppsIdx),
    case getopt(check) of
        true ->
            case AppupChanges of
                [] ->
                    ok;
                _ ->
                    set_invalid(),
                    log("ERROR: The appup files are incomplete. Missing changes:~n   ~p", [AppupChanges])
            end;
        false ->
            update_appups(AppupChanges)
    end,
    check_appup_files(),
    warn_and_exit(is_valid()).

warn_and_exit(true) ->
    log("
NOTE: Please review the changes manually. This script does not know about NIF
changes, supervisor changes, process restarts and so on. Also the load order of
the beam files might need updating.~n"),
    halt(0);
warn_and_exit(false) ->
    log("~nERROR: Incomplete appups found. Please inspect the output for more details.~n"),
    halt(1).

prepare(Baseline, Options = #{make_command := MakeCommand, beams_dir := BeamDir}) ->
    log("~n===================================~n"
        "Baseline: ~s"
        "~n===================================~n", [Baseline]),
    log("Building the current version...~n"),
    bash(MakeCommand),
    log("Downloading and building the previous release...~n"),
    {ok, PredRootDir} = build_pred_release(Baseline, Options),
    {BeamDir, filename:join(PredRootDir, BeamDir)}.

build_pred_release(Baseline, #{clone_url := Repo, make_command := MakeCommand}) ->
    BaseDir = "/tmp/emqx-baseline/",
    Dir = filename:basename(Repo, ".git") ++ [$-|Baseline],
    %% TODO: shallow clone
    Script = "mkdir -p ${BASEDIR} &&
              cd ${BASEDIR} &&
              { [ -d ${DIR} ] || git clone --branch ${TAG} ${REPO} ${DIR}; } &&
              cd ${DIR} &&" ++ MakeCommand,
    Env = [{"REPO", Repo}, {"TAG", Baseline}, {"BASEDIR", BaseDir}, {"DIR", Dir}],
    bash(Script, Env),
    {ok, filename:join(BaseDir, Dir)}.

find_upstream_repo(Remote) ->
    string:trim(os:cmd("git remote get-url " ++ Remote)).

find_pred_tag(CurrentRelease) ->
    case getopt(prev_tag) of
        undefined ->
            {Maj, Min, Patch} = parse_semver(CurrentRelease),
            case Patch of
                0 -> undefined;
                _ -> {ok, semver(Maj, Min, Patch - 1)}
            end;
        Tag ->
            {ok, Tag}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Appup action creation and updating
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

find_appup_actions(CurrApps, PredApps) ->
    maps:fold(
      fun(App, CurrAppIdx, Acc) ->
              case PredApps of
                  #{App := PredAppIdx} -> find_appup_actions(App, CurrAppIdx, PredAppIdx) ++ Acc;
                  _                    -> Acc %% New app, nothing to upgrade here.
              end
      end,
      [],
      CurrApps).

find_appup_actions(_App, AppIdx, AppIdx) ->
    %% No changes to the app, ignore:
    [];
find_appup_actions(App, CurrAppIdx, PredAppIdx = #app{version = PredVersion}) ->
    {OldUpgrade, OldDowngrade} = find_old_appup_actions(App, PredVersion),
    Upgrade = merge_update_actions(diff_app(App, CurrAppIdx, PredAppIdx), OldUpgrade),
    Downgrade = merge_update_actions(diff_app(App, PredAppIdx, CurrAppIdx), OldDowngrade),
    if OldUpgrade =:= Upgrade andalso OldDowngrade =:= Downgrade ->
            %% The appup file has been already updated:
            [];
       true ->
            [{App, {Upgrade, Downgrade}}]
    end.

find_old_appup_actions(App, PredVersion) ->
    {Upgrade0, Downgrade0} =
        case locate(App, ".appup.src") of
            {ok, AppupFile} ->
                {_, U, D} = read_appup(AppupFile),
                {U, D};
            undefined ->
                {[], []}
        end,
    {ensure_version(PredVersion, Upgrade0), ensure_version(PredVersion, Downgrade0)}.

merge_update_actions(Changes, Vsns) ->
    lists:map(fun(Ret = {<<".*">>, _}) ->
                      Ret;
                 ({Vsn, Actions}) ->
                      {Vsn, do_merge_update_actions(Changes, Actions)}
              end,
              Vsns).

do_merge_update_actions({New0, Changed0, Deleted0}, OldActions) ->
    AlreadyHandled = lists:flatten(lists:map(fun process_old_action/1, OldActions)),
    New = New0 -- AlreadyHandled,
    Changed = Changed0 -- AlreadyHandled,
    Deleted = Deleted0 -- AlreadyHandled,
    [{load_module, M, brutal_purge, soft_purge, []} || M <- Changed ++ New] ++
        OldActions ++
        [{delete_module, M} || M <- Deleted].


%% @doc Process the existing actions to exclude modules that are
%% already handled
process_old_action({purge, Modules}) ->
    Modules;
process_old_action({delete_module, Module}) ->
    [Module];
process_old_action(LoadModule) when is_tuple(LoadModule) andalso
                                    element(1, LoadModule) =:= load_module ->
    element(2, LoadModule);
process_old_action(_) ->
    [].

ensure_version(Version, Versions) ->
    case lists:keyfind(Version, 1, Versions) of
        false ->
            [{Version, []}|Versions];
        _ ->
            Versions
    end.

read_appup(File) ->
    %% NOTE: appup file is a script, it may contain variables or functions.
    case file:script(File, [{'VSN', "VSN"}]) of
        {ok, Terms} ->
            Terms;
        Error ->
            fail("Failed to parse appup file ~s: ~p", [File, Error])
    end.

check_appup_files() ->
    AppupFiles = filelib:wildcard(getopt(src_dirs) ++ "/*.appup.src"),
    lists:foreach(fun read_appup/1, AppupFiles).

update_appups(Changes) ->
    lists:foreach(
      fun({App, {Upgrade, Downgrade}}) ->
              do_update_appup(App, Upgrade, Downgrade)
      end,
      Changes).

do_update_appup(App, Upgrade, Downgrade) ->
    case locate(App, ".appup.src") of
        {ok, AppupFile} ->
            render_appfile(AppupFile, Upgrade, Downgrade);
        undefined ->
            case create_stub(App) of
                {ok, AppupFile} ->
                    render_appfile(AppupFile, Upgrade, Downgrade);
                false ->
                    set_invalid(),
                    log("ERROR: Appup file for the external dependency '~p' is not complete.~n       Missing changes: ~p", [App, Upgrade])
            end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Appup file creation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

render_appfile(File, Upgrade, Downgrade) ->
    IOList = io_lib:format("%% -*- mode: erlang -*-\n{VSN,~n  ~p,~n  ~p}.~n", [Upgrade, Downgrade]),
    ok = file:write_file(File, IOList).

create_stub(App) ->
    case locate(App, ".app.src") of
        {ok, AppSrc} ->
            AppupFile = filename:basename(AppSrc) ++ ".appup.src",
            Default = {<<".*">>, []},
            render_appfile(AppupFile, [Default], [Default]),
            AppupFile;
        undefined ->
            false
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% application and release indexing
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

index_apps(ReleaseDir) ->
    maps:from_list([index_app(filename:join(ReleaseDir, AppFile)) ||
                       AppFile <- filelib:wildcard("**/ebin/*.app", ReleaseDir)]).

index_app(AppFile) ->
    {ok, [{application, App, Properties}]} = file:consult(AppFile),
    Vsn = proplists:get_value(vsn, Properties),
    %% Note: assuming that beams are always located in the same directory where app file is:
    EbinDir = filename:dirname(AppFile),
    Modules = hashsums(EbinDir),
    {App, #app{ version       = Vsn
              , modules       = Modules
              }}.

diff_app(App, #app{version = NewVersion, modules = NewModules}, #app{version = OldVersion, modules = OldModules}) ->
    {New, Changed} =
        maps:fold( fun(Mod, MD5, {New, Changed}) ->
                           case OldModules of
                               #{Mod := OldMD5} when MD5 =:= OldMD5 ->
                                   {New, Changed};
                               #{Mod := _} ->
                                   {New, [Mod|Changed]};
                               _ ->
                                   {[Mod|New], Changed}
                           end
                   end
                 , {[], []}
                 , NewModules
                 ),
    Deleted = maps:keys(maps:without(maps:keys(NewModules), OldModules)),
    NChanges = length(New) + length(Changed) + length(Deleted),
    if NewVersion =:= OldVersion andalso NChanges > 0 ->
            set_invalid(),
            log("ERROR: Application '~p' contains changes, but its version is not updated", [App]);
       true ->
            ok
    end,
    {New, Changed, Deleted}.

-spec hashsums(file:filename()) -> #{module() => binary()}.
hashsums(EbinDir) ->
    maps:from_list(lists:map(
                     fun(Beam) ->
                             File = filename:join(EbinDir, Beam),
                             {ok, Ret = {_Module, _MD5}} = beam_lib:md5(File),
                             Ret
                     end,
                     filelib:wildcard("*.beam", EbinDir)
                    )).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Global state
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init_globals(Options) ->
    ets:new(globals, [named_table, set, public]),
    ets:insert(globals, {valid, true}),
    ets:insert(globals, {options, Options}).

getopt(Option) ->
    maps:get(Option, ets:lookup_element(globals, options, 2)).

%% Set a global flag that something about the appfiles is invalid
set_invalid() ->
    ets:insert(globals, {valid, false}).

is_valid() ->
    ets:lookup_element(globals, valid, 2).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Utility functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse_semver(Version) ->
    case re(Version, "^([0-9]+)\\.([0-9]+)\\.([0-9]+)(\\.[0-9]+)?$") of
        {match, [Maj, Min, Patch|_]} ->
            {list_to_integer(Maj), list_to_integer(Min), list_to_integer(Patch)};
        _ ->
            error({not_a_semver, Version})
    end.

semver(Maj, Min, Patch) ->
    lists:flatten(io_lib:format("~p.~p.~p", [Maj, Min, Patch])).

%% Locate a file in a specified application
locate(App, Suffix) ->
    AppStr = atom_to_list(App),
    SrcDirs = getopt(src_dirs),
    case filelib:wildcard(SrcDirs ++ AppStr ++ Suffix) of
        [File] ->
            {ok, File};
        [] ->
            undefined
    end.

bash(Script) ->
    bash(Script, []).

bash(Script, Env) ->
    case cmd("bash", #{args => ["-c", Script], env => Env}) of
        0 -> true;
        _ -> fail("Failed to run command: ~s", [Script])
    end.

%% Spawn an executable and return the exit status
cmd(Exec, Params) ->
    case os:find_executable(Exec) of
        false ->
            fail("Executable not found in $PATH: ~s", [Exec]);
        Path ->
            Params1 = maps:to_list(maps:with([env, args, cd], Params)),
            Port = erlang:open_port( {spawn_executable, Path}
                                   , [ exit_status
                                     , nouse_stdio
                                     | Params1
                                     ]
                                   ),
            receive
                {Port, {exit_status, Status}} ->
                    Status
            end
    end.

fail(Str) ->
    fail(Str, []).

fail(Str, Args) ->
    log(Str ++ "~n", Args),
    halt(1).

re(Subject, RE) ->
    re:run(Subject, RE, [{capture, all_but_first, list}]).

log(Msg) ->
    log(Msg, []).

log(Msg, Args) ->
    io:format(standard_error, Msg, Args).
