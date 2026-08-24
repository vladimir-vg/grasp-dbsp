%%%-------------------------------------------------------------------
%%% @doc Barrier-aware 1:1 row transformation.
%%%
%%% Single-upstream stateless pass-through. Applies Fun to every
%%% row, preserves weights and Meta (including barrier tag).
%%% @end
%%%-------------------------------------------------------------------
-module(gdbsp_op_map).

-behaviour(gdbsp_operator_spec).

-export([init/1]).
-export([handle_delta/3]).
-export([merge_metas/1]).

-include("gdbsp_op.hrl").
-include("gdbsp_debug.hrl").

-type op_state() :: #{
    'fun'      := fun((term()) -> term()),
    downstream_label := term()
}.

-export_type([op_state/0, op_action/0]).

-spec init(map()) -> {op_state(), [term()], [term()]}.
init(#{kind := rename, columns := ColMap}) ->
    Fun = build_rename_fn(ColMap),
    {#{'fun' => Fun, downstream_label => default}, [default], [default]};
init(#{kind := project, keep := KeepVars} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    Fun = fun({value, {struct, _, _}, _} = Row) ->
        Value:struct_project(Row, KeepVars)
    end,
    {#{'fun' => Fun, downstream_label => default}, [default], [default]};
init(#{kind := head_rename, columns := HeadCols}) ->
    Fun = build_head_rename_fn(HeadCols),
    {#{'fun' => Fun, downstream_label => default}, [default], [default]};
init(#{kind := agg_unwrap, group_by := GroupBy,
       output_var := OutVar, row_type := RowType} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    Fun = build_agg_unwrap_fn(Value, GroupBy, OutVar, RowType),
    {#{'fun' => Fun, downstream_label => default}, [default], [default]};
init(#{kind := wrap, row_type := RowType} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    Fun = fun({value, _, _} = Row) -> Row;
              (Row) -> Value:map_to_struct(Row, RowType)
         end,
    {#{'fun' => Fun, downstream_label => default}, [default], [default]};
init(#{expr := Expr, row_type := _RowType} = Args) ->
    Value = maps:get(value_mod, Args, gdbsp_value),
    ArgName = maps:get(arg_name, Args, <<"row">>),
    KwargOrder = maps:get(kwarg_order, Args, #{}),
    case maps:find(out, Args) of
        {ok, OutCol} ->
            Fun = fun(Row) ->
                case Value:eval_expr(Expr, Row, ArgName, KwargOrder) of
                    {ok, {value, OutType, ResultVal}} ->
                        Value:struct_extend(Row, OutCol, {value, OutType, ResultVal});
                    drop_row -> erlang:throw(drop_row);
                    {error, _} -> erlang:throw(drop_row)
                end
            end;
        error ->
            Fun = fun(Row) ->
                case Value:eval_expr(Expr, Row, ArgName, KwargOrder) of
                    {ok, {value, _, _} = Result} -> Result;
                    drop_row -> erlang:throw(drop_row);
                    {error, _} -> erlang:throw(drop_row)
                end
            end
    end,
    {#{'fun' => Fun, downstream_label => default}, [default], [default]}.

-spec handle_delta(op_state(), term(), {delta, map(), [term()]}) ->
    {op_state(), [op_action()]}.
handle_delta(#{'fun' := Fun, downstream_label := Label} = St, default,
             {delta, Meta, Deltas}) ->
    Transformed = lists:filtermap(fun({W, Row}) ->
        try {true, {W, Fun(Row)}}
        catch
            throw:drop_row ->
                ?DBG("OP map pid=~p DROP ROW: kind=~p",
                       [self(), row_kind(Row)]),
                false;
            C:E:Stk ->
                ?DBG("OP map pid=~p CRASH: ~p:~p row=~p",
                       [self(), C, E, row_kind(Row)]),
                false
        end
    end, Deltas),
    {St, gdbsp_operator_spec:maybe_emit(Label, Meta, Transformed)}.

row_kind({value, {struct, Fs, _}, _}) -> {struct, maps:keys(Fs)};
row_kind(M) when is_map(M) -> {map, maps:keys(M)};
row_kind(T) when is_tuple(T) -> {tuple, tuple_size(T)};
row_kind(_) -> other.

-spec merge_metas(#{term() => map()}) -> map().
merge_metas(_) -> #{}.

%%--------------------------------------------------------------------
%% Symbolic spec → closure builders
%%--------------------------------------------------------------------

build_rename_fn(ColMap) when map_size(ColMap) =:= 0 ->
    fun(Row) -> Row end;
build_rename_fn(ColMap) ->
    fun({value, {struct, _Fields, Rest}, TypedValues}) ->
        {NewVals, NewFields} = maps:fold(fun(OldKey, Value, {VA, FA}) ->
            NewVar = rename_new_var(Value),
            case maps:find(OldKey, TypedValues) of
                {ok, {value, FldType, _} = TypedVal} ->
                    {VA#{NewVar => TypedVal},
                     FA#{NewVar => FldType}};
                error -> {VA, FA}
            end
        end, {#{}, #{}}, ColMap),
        {value, {struct, NewFields, Rest}, NewVals};
       (Row) ->
        maps:fold(fun(OldKey, Value, Acc) ->
            NewVar = rename_new_var(Value),
            case maps:find(OldKey, Row) of
                {ok, Val} -> maps:put(NewVar, Val, Acc);
                error -> Acc
            end
        end, #{}, ColMap)
    end.

rename_new_var(#{var := V}) -> V;
rename_new_var(V) when is_binary(V) -> V.

%% Rename body-var-keyed struct columns to head-column-keyed columns.
%% Each value's own runtime type tag is preserved verbatim and the field-type
%% map is derived from the values — mirroring build_rename_fn. head_cols carry
%% no declared type, so the input struct's Fields map must NOT be used to
%% re-type values: doing so downgrades a refined `{dynamic, T}` value tag to
%% the bare schema `dynamic` for join/antijoin/aggregate-derived structs (see
%% gg_compiler/docs/value-type-representation-hardening.md).
build_head_rename_fn(HeadCols) ->
    fun({value, {struct, _Fields, Rest}, TypedValues}) ->
        {NewFields, NewColVals} =
            maps:fold(fun(Col, #{var := Var}, {FA, VA}) ->
                case maps:find(Var, TypedValues) of
                    {ok, {value, Type, _} = TypedVal} ->
                        {FA#{Col => Type}, VA#{Col => TypedVal}};
                    error -> {FA, VA}
                end
            end, {#{}, #{}}, HeadCols),
        {value, {struct, NewFields, Rest}, NewColVals}
    end.

%%--------------------------------------------------------------------
%% Aggregate-unwrap row builder + KV-tuple helper.

build_agg_unwrap_fn(Value, [], OutVar, RowType) ->
    fun({_Key, Result}) ->
        Value:map_to_struct(#{OutVar => Result}, RowType)
    end;
build_agg_unwrap_fn(Value, [G], OutVar, RowType) ->
    fun({Key, Result}) ->
        Value:map_to_struct(#{G => Key, OutVar => Result}, RowType)
    end;
build_agg_unwrap_fn(Value, GroupBy, OutVar, RowType) ->
    fun({Key, Result}) ->
        Map = kv_tuple_to_map(GroupBy, Key),
        Value:map_to_struct(maps:put(OutVar, Result, Map), RowType)
    end.

kv_tuple_to_map(Vars, Tuple) when is_tuple(Tuple), tuple_size(Tuple) =:= length(Vars) ->
    lists:foldl(fun({V, I}, Acc) ->
        maps:put(V, element(I, Tuple), Acc)
    end, #{}, lists:zip(Vars, lists:seq(1, tuple_size(Tuple))));
kv_tuple_to_map([V], Val) ->
    #{V => Val}.
