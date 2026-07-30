%%%-------------------------------------------------------------------
%%% @doc Grasp type catalog — canonical type definition for the Grasp
%%% type system. Shared between gg-storage and grasp projects.
%%% @end
%%%-------------------------------------------------------------------

-ifndef(GDBSP_TYPE_HRL).
-define(GDBSP_TYPE_HRL, true).

-define(BOOL, {enum, [<<"false">>, <<"true">>]}).

%% Descriptor / schema type: the full type language. Bare `dynamic`/`json`
%% and the type-system-only constructs (`type`, `{type_var,_}`,
%% `{type_predicate,_,_}`) are legal here. Used for relation column decls,
%% struct field maps, container/optional/closure components, join
%% `merged_fields`, function/aggregate signatures, and `{type, T}` arguments.
-type gdbsp_column_type() ::
      i8 | i16 | i32 | i64 | u8 | u16 | u32 | u64
    | integer | f32 | f64 | numeric | string | string_with_encoding
    | bytes | bits
    | date | time | timestamp | timestamp_with_timezone | interval
    | json | dynamic
    | {dynamic, gdbsp_column_type()}
    | {json, gdbsp_column_type()}
    | absent   %% Internal-only: type of the ABSENT literal; erased after typechecking
    | type   %% Internal-only: meta-type; {value, type, T} wraps a gdbsp_column_type()
    | {stream, gdbsp_column_type()}
    | {optional, gdbsp_column_type()}
    | {closure, [{binary(), gdbsp_column_type()}], gdbsp_column_type()}
    | {array, gdbsp_column_type(), varsize | pos_integer() | [pos_integer()]}
    | {map, gdbsp_column_type(), gdbsp_column_type()}
    | {struct, #{binary() => gdbsp_column_type()}, exact | wildcard | binary()}
    | {numeric, pos_integer(), pos_integer()}
    | {bytes, pos_integer()}
    | {bits, pos_integer()}
    | {string, binary()}
    | {type_var, binary()}
    | {type_predicate, binary(), [gdbsp_column_type()]}
    | {enum, [binary()]}.

%% Value tag: the outermost type tag legal on a runtime `{value, T, V}`.
%% A value always carries its concrete inner type, so bare `dynamic`/`json`
%% are excluded (Phase 1/2 of value-type-representation-hardening.md), as are
%% the type-system-only `{type_var,_}`/`{type_predicate,_,_}` and the meta-type
%% `type` (a type argument is the distinct term `{type, gdbsp_column_type()}`,
%% not a value — Phase 2b). Container, optional, and closure COMPONENTS are
%% descriptors (`gdbsp_column_type()`).
%%
%% `absent` stays: it is a well-formed, serialized first-class value. Its sole
%% legal term is `{value, absent, absent}` (plus `{value, {optional, T}, absent}`
%% for typed-optional absence, a different tag).
-type gdbsp_value_type() ::
      i8 | i16 | i32 | i64 | u8 | u16 | u32 | u64
    | integer | f32 | f64 | numeric | string | string_with_encoding
    | bytes | bits
    | date | time | timestamp | timestamp_with_timezone | interval
    | {dynamic, gdbsp_column_type()}
    | {json, gdbsp_column_type()}
    | absent   %% sole legal term: {value, absent, absent}
    | {optional, gdbsp_column_type()}
    | {closure, [{binary(), gdbsp_column_type()}], gdbsp_column_type()}
    | {array, gdbsp_column_type(), varsize | pos_integer() | [pos_integer()]}
    | {map, gdbsp_column_type(), gdbsp_column_type()}
    | {struct, #{binary() => gdbsp_column_type()}, exact | wildcard | binary()}
    | {numeric, pos_integer(), pos_integer()}
    | {bytes, pos_integer()}
    | {bits, pos_integer()}
    | {string, binary()}
    | {enum, [binary()]}.

-type value() :: {value, gdbsp_value_type(), term()}.

%% A type used as a runtime argument (2nd operand of `is`/`ensure`, 1st of
%% `struct(Type, map)`). Distinct from `value()` — a type is not runtime data.
%% In an expression tree a type literal is the leaf `{value, type, T}`; the
%% evaluator lowers it to this term.
-type type_arg() :: {type, gdbsp_column_type()}.

-endif.
