-module(gdbsp_value).

-export([map_to_struct/2, struct_to_map/1, struct_project/2,
         struct_extend/3, unwrap/1,
         wrap_value/2,
         eval_expr/3,
         columns_to_json/1,
         encode_row/2, decode_row/2,
         bytewise_xor/2]).

map_to_struct(RawMap, RowType) -> gdbsp_struct:map_to_struct(RawMap, RowType).
struct_to_map(Struct) -> gdbsp_struct:struct_to_map(Struct).
struct_project(Struct, Fields) -> gdbsp_struct:struct_project(Struct, Fields).
struct_extend(Struct, Key, Value) -> gdbsp_struct:struct_extend(Struct, Key, Value).
unwrap(Value) -> gdbsp_struct:unwrap_value(Value).

wrap_value(Val, Type) -> gdbsp_struct:wrap_value(Val, Type).

eval_expr(Expr, Row, ArgName) -> gdbsp_eval:eval_with_row(Expr, Row, ArgName).

columns_to_json(Columns) -> gdbsp_value_json:columns_to_json(Columns).

encode_row(Type, Row) -> gdbsp_value_json:encode_row(Type, Row).
decode_row(Type, Json) -> gdbsp_value_json:decode_row(Type, Json).

bytewise_xor(A, B) -> gdbsp_agg:bytewise_xor(A, B).
