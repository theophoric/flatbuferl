%% @private
-module(flatbuferl_schema).
-export([parse/1, parse_file/1, process/1, validate/3]).
%% Shared utilities used by builder
-export([uint16_bytes/1, resolve_type/2]).

-ifdef(TEST).
-export([precompute_encode_layout/3]).
-endif.

-include("flatbuferl_records.hrl").

-type type_name() :: atom().
-type field_def() :: {atom(), atom() | tuple()} | {atom(), atom() | tuple(), map()}.
%% Table can be old tuple format or new record format
-type table_def() ::
    #table_def{} | {table, [#field_def{}], [#field_def{}], [#field_def{}], integer()}.
-type enum_def() :: #enum_def{}.
-type union_def() :: #union_def{}.
-type definitions() :: #{type_name() => table_def() | enum_def() | union_def()}.
-type options() :: #{
    namespace => atom(),
    root_type => atom(),
    file_identifier => binary(),
    file_extension => binary(),
    include => [binary()],
    attribute => binary()
}.

-export_type([definitions/0, options/0, field_def/0, validate_opts/0, validation_error/0]).

%% Options for validation:
%%   unknown_fields => ignore | error  (default: ignore)
-type validate_opts() :: #{
    unknown_fields => ignore | error
}.

-type validation_error() ::
    {type_mismatch, atom(), expected_type(), term()}
    | {missing_required, atom()}
    | {unknown_field, atom()}
    | {invalid_enum, atom(), term(), [atom()]}
    | {invalid_union_type, atom(), term(), [atom()]}
    | {invalid_vector_element, atom(), non_neg_integer(), validation_error()}
    | {nested_errors, atom(), [validation_error()]}.

-type expected_type() :: atom() | {vector, atom()} | {enum, atom()} | {union, atom()}.

%% Parse a schema string
-spec parse(string() | binary()) ->
    {ok, {Definitions :: definitions(), Options :: options()}} | {error, term()}.
parse(Schema) when is_binary(Schema) ->
    parse(binary_to_list(Schema));
parse(Schema) when is_list(Schema) ->
    case flatbuferl_lexer:string(Schema) of
        {ok, Tokens, _} ->
            case flatbuferl_parser:parse(Tokens) of
                {ok, Parsed} -> {ok, process(Parsed)};
                {error, _} = Err -> Err
            end;
        {error, _, _} = Err ->
            {error, Err}
    end.

%% Parse a schema file
-spec parse_file(file:filename()) -> {ok, {map(), map()}} | {error, term()}.
parse_file(Filename) ->
    AbsPath = filename:absname(Filename),
    parse_file(AbsPath, sets:new()).

%% Internal: parse with cycle detection
-spec parse_file(file:filename(), sets:set(file:filename())) ->
    {ok, {map(), map()}} | {error, term()}.
parse_file(AbsPath, Seen) ->
    case sets:is_element(AbsPath, Seen) of
        true ->
            {error, {circular_include, AbsPath}};
        false ->
            case file:read_file(AbsPath) of
                {ok, Contents} ->
                    BaseDir = filename:dirname(AbsPath),
                    NewSeen = sets:add_element(AbsPath, Seen),
                    parse_with_includes(Contents, BaseDir, NewSeen);
                {error, _} = Err ->
                    Err
            end
    end.

%% Parse content and process includes
parse_with_includes(Schema, BaseDir, Seen) when is_binary(Schema) ->
    parse_with_includes(binary_to_list(Schema), BaseDir, Seen);
parse_with_includes(Schema, BaseDir, Seen) when is_list(Schema) ->
    case flatbuferl_lexer:string(Schema) of
        {ok, Tokens, _} ->
            case flatbuferl_parser:parse(Tokens) of
                {ok, {Defs, Opts}} ->
                    process_includes(Defs, Opts, BaseDir, Seen);
                {error, _} = Err ->
                    Err
            end;
        {error, _, _} = Err ->
            {error, Err}
    end.

%% Process include directives
process_includes(Defs, Opts, BaseDir, Seen) ->
    Includes = maps:get(include, Opts, []),
    case process_includes_list(Includes, Defs, BaseDir, Seen) of
        {ok, MergedDefs} ->
            %% Remove includes from opts (they've been processed)
            CleanOpts = maps:remove(include, Opts),
            {ok, process({MergedDefs, CleanOpts})};
        {error, _} = Err ->
            Err
    end.

process_includes_list([], Defs, _BaseDir, _Seen) ->
    {ok, Defs};
process_includes_list([Include | Rest], Defs, BaseDir, Seen) ->
    IncludePath = filename:absname(binary_to_list(Include), BaseDir),
    case parse_file(IncludePath, Seen) of
        {ok, {IncludedDefs, _IncludedOpts}} ->
            case merge_definitions(Defs, IncludedDefs) of
                {ok, MergedDefs} ->
                    process_includes_list(Rest, MergedDefs, BaseDir, Seen);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% Merge definitions, error on duplicates
merge_definitions(Defs1, Defs2) ->
    Duplicates = maps:keys(maps:with(maps:keys(Defs1), Defs2)),
    case Duplicates of
        [] ->
            {ok, maps:merge(Defs1, Defs2)};
        _ ->
            {error, {duplicate_types, Duplicates}}
    end.

%% Post-process parsed flatbuferl_schema: assign field IDs, validate
%% Two-phase processing:
%%   1. Process enums/unions to add index maps
%%   2. Process tables using enriched defs so resolve_type sees index maps
-spec process({map(), map()}) -> {map(), map()}.
process({Defs, Opts}) ->
    %% Phase 1: enrich enums and unions with precomputed index maps
    EnrichedDefs = maps:map(fun(_Name, Def) -> enrich_def(Def) end, Defs),
    %% Phase 1b: re-enrich structs that contain nested struct fields.
    %% enrich_def doesn't have access to Defs, so nested struct types
    %% (atoms like 'Vec2') get primitive_type_size/1's catch-all (4).
    %% Rebuild each struct's field layout using the latest resolved defs.
    %% Iterate until stable to handle multi-level nesting (A contains B
    %% contains C) where each pass propagates one more level of sizes.
    ReEnrichedDefs = re_enrich_structs_fixpoint(EnrichedDefs),
    %% Phase 2: process tables using enriched definitions
    ProcessedDefs = maps:map(
        fun(_Name, Def) -> process_def(Def, ReEnrichedDefs) end, ReEnrichedDefs
    ),
    {ProcessedDefs, Opts}.

%% Phase 1: add index maps to enums/unions, precompute struct field offsets
enrich_def({union, Members}) ->
    IndexMap = maps:from_list(lists:zip(Members, lists:seq(1, length(Members)))),
    ReverseMap = maps:from_list(lists:zip(lists:seq(1, length(Members)), Members)),
    #union_def{members = Members, index_map = IndexMap, reverse_map = ReverseMap};
enrich_def({{enum, BaseType}, Values}) ->
    %% Values can be atoms (implicit indices) or {Atom, Index} tuples (explicit indices)
    {Names, IndexPairs} = normalize_enum_values(Values),
    IndexMap = maps:from_list(IndexPairs),
    ReverseMap = maps:from_list([{I, N} || {N, I} <- IndexPairs]),
    #enum_def{base_type = BaseType, values = Names, index_map = IndexMap, reverse_map = ReverseMap};
enrich_def({struct, Fields}) ->
    %% Precompute field offsets, sizes, and total struct size for efficient decoding
    {EnrichedFields, RawSize, MaxAlign} = lists:foldl(
        fun({Name, Type}, {Acc, Off, MaxAlignAcc}) ->
            Size = primitive_type_size(Type),
            AlignedOff = align_to(Off, Size),
            ResolvedType = resolve_struct_field_type(Type),
            Field = #{
                name => Name,
                binary_name => atom_to_binary(Name),
                type => ResolvedType,
                offset => AlignedOff,
                size => Size
            },
            {[Field | Acc], AlignedOff + Size, max(MaxAlignAcc, Size)}
        end,
        {[], 0, 1},
        Fields
    ),
    TotalSize = align_to(RawSize, MaxAlign),
    #struct_def{fields = lists:reverse(EnrichedFields), total_size = TotalSize};
enrich_def(Other) ->
    Other.

%% Re-enrich struct fields that reference other structs.
%% After Phase 1, nested struct atoms (e.g. 'Vec2') have size 4 from the
%% catch-all. Now re-resolve using EnrichedDefs to get the actual struct
%% size and #struct_def{} type for encode_scalar dispatch.
re_enrich_struct(#struct_def{fields = Fields} = Def, EnrichedDefs) ->
    {ReFields, RawSize, MaxAlign} = lists:foldl(
        fun(
            #{
                name := Name,
                binary_name := BinName,
                type := Type,
                offset := _OldOff,
                size := _OldSize
            },
            {Acc, Off, MaxA}
        ) ->
            {ResolvedType, Size} = resolve_struct_field(Type, EnrichedDefs),
            AlignedOff = align_to(Off, Size),
            Field = #{
                name => Name,
                binary_name => BinName,
                type => ResolvedType,
                offset => AlignedOff,
                size => Size
            },
            {[Field | Acc], AlignedOff + Size, max(MaxA, Size)}
        end,
        {[], 0, 1},
        Fields
    ),
    TotalSize = align_to(RawSize, MaxAlign),
    Def#struct_def{fields = lists:reverse(ReFields), total_size = TotalSize};
re_enrich_struct(Other, _EnrichedDefs) ->
    Other.

%% Iterate re-enrichment until no struct definitions change.
%% Each pass starts from the original Phase 1 defs (with atom field types)
%% and resolves using the latest enriched defs, so nested struct types pick
%% up sizes from already-resolved structs. Converges in N passes for
%% N levels of struct nesting.
re_enrich_structs_fixpoint(Phase1Defs) ->
    re_enrich_structs_fixpoint(Phase1Defs, Phase1Defs).

re_enrich_structs_fixpoint(OriginalDefs, CurrentDefs) ->
    Next = maps:map(
        fun(_Name, Def) -> re_enrich_struct(Def, CurrentDefs) end, OriginalDefs
    ),
    case Next =:= CurrentDefs of
        true -> CurrentDefs;
        false -> re_enrich_structs_fixpoint(OriginalDefs, Next)
    end.

%% Resolve a single struct field type against enriched defs
resolve_struct_field(Type, EnrichedDefs) when is_atom(Type) ->
    case maps:get(Type, EnrichedDefs, undefined) of
        #struct_def{total_size = Size} = StructDef ->
            {StructDef, Size};
        #enum_def{base_type = Base, index_map = IM, reverse_map = RM} ->
            Resolved = #enum_resolved{
                base_type = normalize_scalar_type(Base),
                index_map = IM,
                reverse_map = RM
            },
            {Resolved, primitive_type_size(Base)};
        _ ->
            {normalize_scalar_type(Type), primitive_type_size(Type)}
    end;
resolve_struct_field(#struct_def{total_size = Size} = StructDef, _) ->
    {StructDef, Size};
resolve_struct_field(#array_def{total_size = Size} = ArrayDef, _) ->
    {ArrayDef, Size};
resolve_struct_field(Type, _) ->
    {Type, primitive_type_size(Type)}.

%% Resolve types within struct fields (arrays need #array_def{})
resolve_struct_field_type({array, ElemType, Count}) ->
    AsBinary = ElemType == byte orelse ElemType == ubyte,
    NormElem = normalize_scalar_type(ElemType),
    ElemSize = primitive_type_size(ElemType),
    #array_def{
        element_type = NormElem,
        count = Count,
        element_size = ElemSize,
        total_size = ElemSize * Count,
        as_binary = AsBinary
    };
resolve_struct_field_type(Type) ->
    normalize_scalar_type(Type).

%% Normalize enum values: handles both implicit indices (atoms) and explicit indices ({Atom, Index} tuples)
normalize_enum_values(Values) ->
    normalize_enum_values(Values, 0, [], []).

normalize_enum_values([], _NextIdx, NamesAcc, PairsAcc) ->
    {lists:reverse(NamesAcc), lists:reverse(PairsAcc)};
normalize_enum_values([{Name, Index} | Rest], _NextIdx, NamesAcc, PairsAcc) when
    is_atom(Name), is_integer(Index)
->
    %% Explicit index
    normalize_enum_values(Rest, Index + 1, [Name | NamesAcc], [{Name, Index} | PairsAcc]);
normalize_enum_values([Name | Rest], NextIdx, NamesAcc, PairsAcc) when is_atom(Name) ->
    %% Implicit index
    normalize_enum_values(Rest, NextIdx + 1, [Name | NamesAcc], [{Name, NextIdx} | PairsAcc]).

%% Type size for struct field alignment (primitive types only)
primitive_type_size(bool) -> 1;
primitive_type_size(byte) -> 1;
primitive_type_size(ubyte) -> 1;
primitive_type_size(int8) -> 1;
primitive_type_size(uint8) -> 1;
primitive_type_size(short) -> 2;
primitive_type_size(ushort) -> 2;
primitive_type_size(int16) -> 2;
primitive_type_size(uint16) -> 2;
primitive_type_size(int) -> 4;
primitive_type_size(uint) -> 4;
primitive_type_size(int32) -> 4;
primitive_type_size(uint32) -> 4;
primitive_type_size(long) -> 8;
primitive_type_size(ulong) -> 8;
primitive_type_size(int64) -> 8;
primitive_type_size(uint64) -> 8;
primitive_type_size(float) -> 4;
primitive_type_size(float32) -> 4;
primitive_type_size(double) -> 8;
primitive_type_size(float64) -> 8;
primitive_type_size({array, ElemType, Count}) -> primitive_type_size(ElemType) * Count;
primitive_type_size(_) -> 4.

align_to(Off, Align) ->
    case Off rem Align of
        0 -> Off;
        R -> Off + (Align - R)
    end.

%% Phase 2: process tables (enums/unions already enriched, pass through)
process_def({table, Fields}, Defs) ->
    %% Expand union fields into type + value pairs before assigning IDs
    ExpandedFields = expand_union_fields(Fields, Defs),
    %% Fix enum default values (parser stores as binary, need atom)
    NormalizedFields = normalize_enum_defaults(ExpandedFields, Defs),
    %% Assign field IDs
    FieldsWithIds = assign_field_ids(NormalizedFields),
    %% Convert to #field_def{} records with precomputed values
    FieldDefs = [optimize_field_to_record(F, Defs) || F <- FieldsWithIds],
    %% Pre-sort fields by layout order (size desc, id desc) for encoding
    SortedFields = lists:sort(
        fun(#field_def{layout_key = A}, #field_def{layout_key = B}) -> A > B end,
        FieldDefs
    ),
    %% Pre-partition into scalars and refs (eliminates runtime partitioning)
    {Scalars, Refs} = lists:partition(fun(#field_def{is_scalar = S}) -> S end, SortedFields),
    AllFields = Scalars ++ Refs,
    %% Precompute max field id
    MaxId =
        case AllFields of
            [] -> -1;
            _ -> lists:max([F#field_def.id || F <- AllFields])
        end,
    %% Build field name -> field_def map for O(1) lookup
    FieldMap = maps:from_list([{F#field_def.name, F} || F <- AllFields]),
    %% Precompute encoding layout for fast encoding
    EncodeLayout = precompute_encode_layout(Scalars, Refs, MaxId),
    #table_def{
        scalars = Scalars,
        refs = Refs,
        all_fields = AllFields,
        field_map = FieldMap,
        encode_layout = EncodeLayout,
        max_id = MaxId
    };
process_def(Other, _Defs) ->
    %% Enums, unions, structs already processed in phase 1
    Other.

%% Convert field tuple to #field_def{} record with precomputed values
optimize_field_to_record({Name, Type, Attrs}, Defs) ->
    NormalizedType = normalize_type(Type),
    Id = maps:get(id, Attrs, 0),
    InlineSize = field_inline_size(NormalizedType, Defs),
    ResolvedType0 = resolve_type(NormalizedType, Defs),
    %% For union_value_def, set type_field_id and type field names now
    ResolvedType = finalize_resolved_type(ResolvedType0, Id, Name),
    #field_def{
        name = Name,
        binary_name = atom_to_binary(Name),
        id = Id,
        vtable_slot_offset = Id * 2,
        type = NormalizedType,
        default = extract_default(Type),
        required = maps:get(required, Attrs, false),
        deprecated = maps:get(deprecated, Attrs, false),
        inline_size = InlineSize,
        is_scalar = is_scalar_type(NormalizedType, Defs),
        is_primitive = is_primitive_scalar(ResolvedType),
        resolved_type = ResolvedType,
        layout_key = InlineSize * 65536 + Id
    };
optimize_field_to_record({Name, Type}, Defs) ->
    NormalizedType = normalize_type(Type),
    InlineSize = field_inline_size(NormalizedType, Defs),
    ResolvedType0 = resolve_type(NormalizedType, Defs),
    ResolvedType = finalize_resolved_type(ResolvedType0, 0, Name),
    #field_def{
        name = Name,
        binary_name = atom_to_binary(Name),
        id = 0,
        vtable_slot_offset = 0,
        type = NormalizedType,
        default = extract_default(Type),
        required = false,
        deprecated = false,
        inline_size = InlineSize,
        is_scalar = is_scalar_type(NormalizedType, Defs),
        is_primitive = is_primitive_scalar(ResolvedType),
        resolved_type = ResolvedType,
        layout_key = InlineSize * 65536
    }.

%% Convert partial union_value to complete union_value_def with field ID info
finalize_resolved_type(
    #union_value_partial{name = Name, index_map = IndexMap, reverse_map = ReverseMap},
    FieldId,
    FieldName
) ->
    TypeName = list_to_atom(atom_to_list(FieldName) ++ "_type"),
    TypeBinaryName = atom_to_binary(TypeName),
    TypeFieldId = FieldId - 1,
    #union_value_def{
        name = Name,
        index_map = IndexMap,
        reverse_map = ReverseMap,
        type_field_id = TypeFieldId,
        type_vtable_slot_offset = TypeFieldId * 2,
        type_name = TypeName,
        type_binary_name = TypeBinaryName
    };
%% Vector elements with union_value_partial stay partial - builder handles them
%% differently (computes type names from vector field name, not element)
finalize_resolved_type(Other, _FieldId, _FieldName) ->
    Other.

%% True for primitive scalar types (11 canonical types + enums + fixed-size inline types)
is_primitive_scalar(bool) -> true;
is_primitive_scalar(int8) -> true;
is_primitive_scalar(uint8) -> true;
is_primitive_scalar(int16) -> true;
is_primitive_scalar(uint16) -> true;
is_primitive_scalar(int32) -> true;
is_primitive_scalar(uint32) -> true;
is_primitive_scalar(int64) -> true;
is_primitive_scalar(uint64) -> true;
is_primitive_scalar(float32) -> true;
is_primitive_scalar(float64) -> true;
is_primitive_scalar(#enum_resolved{}) -> true;
is_primitive_scalar(#union_type_def{}) -> true;
is_primitive_scalar(#struct_def{}) -> true;
is_primitive_scalar(#array_def{}) -> true;
is_primitive_scalar(_) -> false.

%% Check if a resolved element type is a table (for vector element detection)
%% Must handle both {table, _} format (during Phase 2) and #table_def{} format
is_table_type(Type, Defs) when is_atom(Type) ->
    case maps:get(Type, Defs, undefined) of
        #table_def{} -> true;
        {table, _} -> true;
        _ -> false
    end;
is_table_type(_, _) ->
    false.

%% Precompute encoding layout for "all fields present" case
%% This allows O(1) encoding when all fields have values
precompute_encode_layout(Scalars, Refs, MaxId) ->
    %% Merge and sort by layout_key (size desc, id desc) for backward placement
    AllFields = lists:sort(
        fun(#field_def{layout_key = A}, #field_def{layout_key = B}) -> A > B end,
        Scalars ++ Refs
    ),
    %% Calculate table layout for all fields present
    {Slots, TableSize} = calc_all_present_layout(AllFields),
    %% Build vtable bytes
    VTableSize = 4 + ((MaxId + 1) * 2),
    VTable = build_precomputed_vtable(MaxId, Slots, TableSize),
    %% Collect all field IDs for quick "all present" check
    AllFieldIds = [F#field_def.id || F <- AllFields],
    %% Precompute offset-only slots for fast path
    SlotOffsets = maps:map(fun(_Id, {Offset, _Size}) -> Offset end, Slots),
    #encode_layout{
        vtable = VTable,
        vtable_size = VTableSize,
        table_size = TableSize,
        slots = Slots,
        slot_offsets = SlotOffsets,
        all_field_ids = AllFieldIds,
        max_id = MaxId
    }.

%% Calculate slot offsets for all fields present
%% Returns {SlotsMap, TableSize} where SlotsMap is #{id => {offset, size}}
calc_all_present_layout(AllFields) ->
    %% Fields are already sorted by layout_key (size desc, id desc)
    %% Place them backward from end of table with alignment
    RawSize = lists:sum([F#field_def.inline_size || F <- AllFields]),
    TableDataSize = align_offset(RawSize, 4),
    %% 4 for soffset
    BaseTableSize = 4 + TableDataSize,
    %% Place fields backward with proper alignment, building slot map
    {Slots, _} = lists:foldl(
        fun(#field_def{id = Id, inline_size = Size}, {Acc, EndPos}) ->
            Align = min(Size, 4),
            StartPos = EndPos - Size,
            AlignedStart = align_down(StartPos, Align),
            {Acc#{Id => {AlignedStart, Size}}, AlignedStart}
        end,
        {#{}, BaseTableSize},
        AllFields
    ),
    {Slots, BaseTableSize}.

%% Align offset DOWN to alignment boundary
align_down(Off, Align) ->
    Off - (Off rem Align).

%% Build precomputed vtable bytes
build_precomputed_vtable(-1, _Slots, TableSize) ->
    %% Empty table - use list format to match build_vtable_from_fields
    [uint16_bytes(4), uint16_bytes(TableSize)];
build_precomputed_vtable(MaxId, Slots, TableSize) ->
    NumSlots = MaxId + 1,
    VTableSize = 4 + (NumSlots * 2),
    SlotsList = [
        case maps:get(Id, Slots, undefined) of
            undefined -> uint16_bytes(0);
            {Offset, _Size} -> uint16_bytes(Offset)
        end
     || Id <- lists:seq(0, MaxId)
    ],
    [uint16_bytes(VTableSize), uint16_bytes(TableSize) | SlotsList].

%% Convert uint16 to little-endian 2-byte list (same as builder's uint16_bytes)
uint16_bytes(X) when X < 256 -> [X, 0];
uint16_bytes(V) -> [V band 16#FF, (V bsr 8) band 16#FF].

%% Determine if a type is scalar (stored inline) vs reference (stored via offset)
%% Scalars: primitives, enums, structs, fixed arrays, union type discriminator
%% References: strings, vectors, union values
is_scalar_type(string, _Defs) ->
    false;
is_scalar_type({vector, _}, _Defs) ->
    false;
is_scalar_type({union_value, _}, _Defs) ->
    false;
is_scalar_type({union_type, _}, _Defs) ->
    true;
is_scalar_type(#struct_def{}, _Defs) ->
    true;
is_scalar_type({struct, _}, _Defs) ->
    true;
is_scalar_type({array, _, _}, _Defs) ->
    true;
is_scalar_type(#enum_resolved{}, _Defs) ->
    true;
is_scalar_type(Type, Defs) when is_atom(Type) ->
    case maps:get(Type, Defs, undefined) of
        #struct_def{} -> true;
        {struct, _} -> true;
        #enum_def{} -> true;
        #union_def{} -> false;
        #table_def{} -> false;
        %% Unprocessed table format (during phase 2 processing)
        {table, _} -> false;
        % primitive types
        undefined -> true
    end;
is_scalar_type(_, _Defs) ->
    false.

%% Normalize type: strip default value wrapper, but preserve type constructors
normalize_type({Type, _Default}) when
    is_atom(Type),
    Type /= vector,
    Type /= enum,
    Type /= struct,
    Type /= array,
    Type /= union_type,
    Type /= union_value
->
    Type;
normalize_type(Type) ->
    Type.

%% Resolve type name to its definition (for enums and structs)
%% This is precomputed into the schema for use during encoding
%% NOTE: Tables are NOT resolved - they stay as atom names for lookup in Defs
%% Only structs are resolved because struct data is encoded inline
resolve_type(Type, Defs) when is_atom(Type) ->
    case maps:get(Type, Defs, undefined) of
        #enum_def{base_type = Base, index_map = IndexMap, reverse_map = ReverseMap} ->
            #enum_resolved{
                base_type = normalize_scalar_type(Base),
                index_map = IndexMap,
                reverse_map = ReverseMap
            };
        #struct_def{} = StructDef ->
            StructDef;
        {struct, Fields} ->
            {struct, Fields};
        % Keep table types as atoms for Defs lookup (both processed and unprocessed)
        #table_def{} ->
            Type;
        {table, _} ->
            Type;
        _ ->
            normalize_scalar_type(Type)
    end;
resolve_type({vector, ElemType}, Defs) ->
    ResolvedElem = resolve_type(ElemType, Defs),
    #vector_def{
        element_type = ResolvedElem,
        is_primitive = is_primitive_scalar(ResolvedElem),
        element_size = vector_element_size(ResolvedElem, Defs),
        is_table_element = is_table_type(ResolvedElem, Defs)
    };
resolve_type({array, ElemType, Count}, Defs) ->
    ResolvedElem = resolve_type(ElemType, Defs),
    AsBinary = ElemType == byte orelse ElemType == ubyte,
    ElemSize = array_element_size(ResolvedElem, Defs),
    #array_def{
        element_type = ResolvedElem,
        count = Count,
        element_size = ElemSize,
        total_size = ElemSize * Count,
        as_binary = AsBinary
    };
resolve_type({union_type, UnionName}, Defs) ->
    #union_def{index_map = IndexMap, reverse_map = ReverseMap} = maps:get(UnionName, Defs),
    #union_type_def{name = UnionName, index_map = IndexMap, reverse_map = ReverseMap};
resolve_type({union_value, UnionName}, Defs) ->
    #union_def{index_map = IndexMap, reverse_map = ReverseMap} = maps:get(UnionName, Defs),
    %% Partial record - finalize_resolved_type converts to union_value_def when field ID is known
    #union_value_partial{name = UnionName, index_map = IndexMap, reverse_map = ReverseMap};
resolve_type(Type, _Defs) ->
    Type.

%% Vector element size - actual inline size for scalars/structs, offset size for refs
vector_element_size(string, _Defs) ->
    4;
%% Union types (record form only - tuple form resolved before this is called)
vector_element_size(#union_type_def{}, _Defs) ->
    1;
vector_element_size(#union_value_def{}, _Defs) ->
    4;
vector_element_size(#enum_resolved{base_type = BaseType}, Defs) ->
    type_size(BaseType, Defs);
vector_element_size(#struct_def{total_size = Size}, _Defs) ->
    Size;
vector_element_size(Type, Defs) when is_atom(Type) ->
    case maps:get(Type, Defs, undefined) of
        % Table reference
        #table_def{} -> 4;
        _ -> type_size(Type, Defs)
    end;
vector_element_size(_, _Defs) ->
    4.

%% Array element size - same logic as vector
array_element_size(Type, Defs) ->
    vector_element_size(Type, Defs).

%% Normalize scalar type aliases to canonical forms for faster pattern matching
%% This eliminates guard conditions like `when Type == int; Type == int32`
normalize_scalar_type(byte) -> int8;
normalize_scalar_type(ubyte) -> uint8;
normalize_scalar_type(short) -> int16;
normalize_scalar_type(ushort) -> uint16;
normalize_scalar_type(int) -> int32;
normalize_scalar_type(uint) -> uint32;
normalize_scalar_type(long) -> int64;
normalize_scalar_type(ulong) -> uint64;
normalize_scalar_type(float) -> float32;
normalize_scalar_type(double) -> float64;
normalize_scalar_type(Type) -> Type.

%% Extract default value from type, but not from type constructors
extract_default({Type, D}) when
    is_atom(Type),
    (is_number(D) orelse is_boolean(D) orelse is_atom(D) orelse is_binary(D)),
    Type /= vector,
    Type /= enum,
    Type /= struct,
    Type /= array,
    Type /= union_type,
    Type /= union_value
->
    D;
extract_default(_) ->
    undefined.

%% Size of field as stored inline in table (refs are 4-byte uoffsets)
field_inline_size(string, _Defs) ->
    4;
field_inline_size({vector, _}, _Defs) ->
    4;
field_inline_size({union_value, _}, _Defs) ->
    4;
field_inline_size({union_type, _}, _Defs) ->
    1;
field_inline_size(#struct_def{total_size = TotalSize}, _Defs) ->
    TotalSize;
field_inline_size({struct, Fields}, Defs) ->
    calc_struct_size(Fields, Defs);
field_inline_size({array, ElemType, Count}, Defs) ->
    type_size(ElemType, Defs) * Count;
field_inline_size(#enum_resolved{base_type = Base}, Defs) ->
    type_size(Base, Defs);
field_inline_size(Type, Defs) when is_atom(Type) ->
    %% Check if it's a user-defined type
    case maps:get(Type, Defs, undefined) of
        #struct_def{total_size = TotalSize} -> TotalSize;
        {struct, Fields} -> calc_struct_size(Fields, Defs);
        #enum_def{base_type = Base} -> type_size(Base, Defs);
        _ -> type_size(Type, Defs)
    end;
field_inline_size(_, _Defs) ->
    4.

%% Type sizes
type_size(bool, _) -> 1;
type_size(byte, _) -> 1;
type_size(ubyte, _) -> 1;
type_size(int8, _) -> 1;
type_size(uint8, _) -> 1;
type_size(short, _) -> 2;
type_size(ushort, _) -> 2;
type_size(int16, _) -> 2;
type_size(uint16, _) -> 2;
type_size(int, _) -> 4;
type_size(uint, _) -> 4;
type_size(int32, _) -> 4;
type_size(uint32, _) -> 4;
type_size(long, _) -> 8;
type_size(ulong, _) -> 8;
type_size(int64, _) -> 8;
type_size(uint64, _) -> 8;
type_size(float, _) -> 4;
type_size(float32, _) -> 4;
type_size(double, _) -> 8;
type_size(float64, _) -> 8;
type_size(#enum_resolved{base_type = Base}, Defs) -> type_size(Base, Defs);
type_size(#struct_def{total_size = TotalSize}, _Defs) -> TotalSize;
type_size({struct, Fields}, Defs) -> calc_struct_size(Fields, Defs);
type_size({array, ElemType, Count}, Defs) -> type_size(ElemType, Defs) * Count;
type_size({union_type, _}, _) -> 1;
type_size(_, _) -> 4.

%% Calculate struct size with proper alignment
%% Handles both raw tuple format {Name, Type} and enriched map format
calc_struct_size(Fields, Defs) ->
    {_, EndOffset, MaxAlign} = lists:foldl(
        fun
            (#{type := _Type, offset := Offset, size := Size}, {_, _, MaxAlignAcc}) ->
                %% Enriched field - use precomputed offset and size
                {ok, Offset + Size, max(MaxAlignAcc, Size)};
            ({_Name, Type}, {_, CurOffset, MaxAlignAcc}) ->
                %% Raw tuple format
                Size = type_size(Type, Defs),
                Align = Size,
                AlignedOffset = align_offset(CurOffset, Align),
                {ok, AlignedOffset + Size, max(MaxAlignAcc, Align)}
        end,
        {ok, 0, 1},
        Fields
    ),
    align_offset(EndOffset, MaxAlign).

align_offset(Off, Align) ->
    case Off rem Align of
        0 -> Off;
        R -> Off + (Align - R)
    end.

%% Expand union fields into type field + value field
expand_union_fields(Fields, Defs) ->
    lists:flatmap(
        fun(Field) ->
            {Name, Type, Attrs} = normalize_field(Field),
            case Type of
                {vector, {union_type, _}} ->
                    %% Already expanded union type vector - pass through
                    [Field];
                {vector, {union_value, _}} ->
                    %% Already expanded union value vector - pass through
                    [Field];
                {vector, ElemType} ->
                    %% Check if element type is a union (match both enriched and raw forms)
                    case maps:get(ElemType, Defs, undefined) of
                        #union_def{} ->
                            %% Vector of union becomes two vector fields
                            TypeFieldName = list_to_atom(atom_to_list(Name) ++ "_type"),
                            [
                                {TypeFieldName, {vector, {union_type, ElemType}}, Attrs},
                                {Name, {vector, {union_value, ElemType}}, Attrs}
                            ];
                        {union, _} ->
                            %% Unenriched union (phase 1)
                            TypeFieldName = list_to_atom(atom_to_list(Name) ++ "_type"),
                            [
                                {TypeFieldName, {vector, {union_type, ElemType}}, Attrs},
                                {Name, {vector, {union_value, ElemType}}, Attrs}
                            ];
                        _ ->
                            [Field]
                    end;
                {union_type, _} ->
                    %% Already expanded union type - pass through
                    [Field];
                {union_value, _} ->
                    %% Already expanded union value - pass through
                    [Field];
                _ ->
                    case maps:get(Type, Defs, undefined) of
                        #union_def{} ->
                            %% Union field becomes two fields: name_type and name
                            TypeFieldName = list_to_atom(atom_to_list(Name) ++ "_type"),
                            [
                                {TypeFieldName, {union_type, Type}, Attrs},
                                {Name, {union_value, Type}, Attrs}
                            ];
                        {union, _} ->
                            %% Unenriched union (phase 1)
                            TypeFieldName = list_to_atom(atom_to_list(Name) ++ "_type"),
                            [
                                {TypeFieldName, {union_type, Type}, Attrs},
                                {Name, {union_value, Type}, Attrs}
                            ];
                        _ ->
                            [Field]
                    end
            end
        end,
        Fields
    ).

normalize_field(#{name := Name, type := Type} = Map) -> {Name, Type, Map};
normalize_field({Name, Type}) -> {Name, Type, #{}};
normalize_field({Name, Type, Attrs}) -> {Name, Type, Attrs}.

%% Fix enum default values: parser stores {EnumType, <<"Value">>}, needs {EnumType, 'Value'}
normalize_enum_defaults(Fields, Defs) ->
    lists:map(fun(Field) -> normalize_enum_default(Field, Defs) end, Fields).

normalize_enum_default({Name, {TypeName, Default}, Attrs}, Defs) when
    is_binary(Default), is_atom(TypeName)
->
    %% 3-tuple with attrs: check if TypeName refers to an enum
    case maps:get(TypeName, Defs, undefined) of
        #enum_def{} ->
            %% Convert binary default to atom
            {Name, {TypeName, binary_to_atom(Default, utf8)}, Attrs};
        _ ->
            %% Not an enum, keep as-is (e.g. string default)
            {Name, {TypeName, Default}, Attrs}
    end;
normalize_enum_default({Name, {TypeName, Default}}, Defs) when
    is_binary(Default), is_atom(TypeName)
->
    %% 2-tuple (no attrs): check if TypeName refers to an enum
    case maps:get(TypeName, Defs, undefined) of
        #enum_def{} ->
            %% Convert binary default to atom
            {Name, {TypeName, binary_to_atom(Default, utf8)}};
        _ ->
            %% Not an enum, keep as-is
            {Name, {TypeName, Default}}
    end;
normalize_enum_default(Field, _Defs) ->
    Field.

%% Assign sequential IDs to fields, respecting explicit IDs
assign_field_ids(Fields) ->
    %% First pass: collect explicit IDs
    ExplicitIds = lists:foldl(
        fun(Field, Acc) ->
            case get_explicit_id(Field) of
                undefined -> Acc;
                Id -> sets:add_element(Id, Acc)
            end
        end,
        sets:new(),
        Fields
    ),

    %% Second pass: assign IDs, filling gaps
    {Processed, _} = lists:mapfoldl(
        fun(Field, NextCandidate) ->
            case get_explicit_id(Field) of
                undefined ->
                    %% Find next available ID starting from NextCandidate
                    AvailableId = find_next_id(NextCandidate, ExplicitIds),
                    {set_field_id(Field, AvailableId), AvailableId + 1};
                _ExplicitId ->
                    %% Field already has ID, don't change NextCandidate
                    {Field, NextCandidate}
            end
        end,
        0,
        Fields
    ),
    Processed.

get_explicit_id(#{id := Id}) ->
    Id;
get_explicit_id({_Name, _Type, Attrs}) when is_map(Attrs) ->
    maps:get(id, Attrs, undefined);
get_explicit_id({_Name, _Type}) ->
    undefined.

set_field_id(#{} = Map, Id) -> Map#{id => Id};
set_field_id({Name, Type, Attrs}, Id) -> {Name, Type, Attrs#{id => Id}};
set_field_id({Name, Type}, Id) -> {Name, Type, #{id => Id}}.

find_next_id(Candidate, ExplicitIds) ->
    case sets:is_element(Candidate, ExplicitIds) of
        true -> find_next_id(Candidate + 1, ExplicitIds);
        false -> Candidate
    end.

%% =============================================================================
%% Validation
%% =============================================================================

-spec validate(map(), {definitions(), options()}, validate_opts()) ->
    ok | {error, [validation_error()]}.
validate(Map, {Defs, SchemaOpts}, Opts) ->
    RootType = maps:get(root_type, SchemaOpts),
    case validate_table(Map, RootType, Defs, Opts) of
        [] -> ok;
        Errors -> {error, Errors}
    end.

validate_table(Map, TableType, Defs, Opts) when is_map(Map) ->
    case maps:get(TableType, Defs, undefined) of
        #table_def{all_fields = Fields} ->
            validate_table_fields(Map, Fields, Defs, Opts);
        undefined ->
            [{unknown_type, TableType}]
    end;
validate_table(Value, TableType, _Defs, _Opts) ->
    [{type_mismatch, TableType, table, Value}].

validate_table_fields(Map, Fields, Defs, Opts) ->
    %% Build set of known field names
    KnownFields = lists:foldl(
        fun(FieldDef, Acc) ->
            Name = get_field_name(FieldDef),
            sets:add_element(Name, Acc)
        end,
        sets:new(),
        Fields
    ),

    %% Check for unknown fields if strict mode
    UnknownErrors =
        case maps:get(unknown_fields, Opts, ignore) of
            error ->
                lists:filtermap(
                    fun(Key) ->
                        KeyAtom = to_field_atom(Key),
                        case sets:is_element(KeyAtom, KnownFields) of
                            true -> false;
                            false -> {true, {unknown_field, KeyAtom}}
                        end
                    end,
                    maps:keys(Map)
                );
            ignore ->
                []
        end,

    %% Validate each field
    FieldErrors = lists:flatmap(
        fun(FieldDef) -> validate_field(Map, FieldDef, Defs, Opts) end,
        Fields
    ),

    UnknownErrors ++ FieldErrors.

validate_field(Map, FieldDef, Defs, Opts) ->
    {Name, Type, Required} = get_field_info(FieldDef),

    case get_map_value(Map, Name) of
        undefined when Required ->
            [{missing_required, Name}];
        undefined ->
            [];
        Value ->
            validate_value(Name, Value, Type, Defs, Opts)
    end.

%% Get field name from either record, map or tuple format
get_field_name(#field_def{name = Name}) -> Name;
get_field_name(#{name := Name}) -> Name;
get_field_name({Name, _Type}) -> Name;
get_field_name({Name, _Type, _Attrs}) -> Name.

%% Get field info from either record, map or tuple format
get_field_info(#field_def{name = Name, type = Type, required = Required}) ->
    {Name, Type, Required};
get_field_info(#{name := Name, type := Type, required := Required}) ->
    {Name, Type, Required};
get_field_info({Name, Type, Attrs}) ->
    {Name, Type, maps:get(required, Attrs, false)};
get_field_info({Name, Type}) ->
    {Name, Type, false}.

get_map_value(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, V} ->
            V;
        error ->
            BinKey = atom_to_binary(Key),
            maps:get(BinKey, Map, undefined)
    end.

to_field_atom(A) when is_atom(A) -> A;
to_field_atom(B) when is_binary(B) ->
    try
        binary_to_existing_atom(B, utf8)
    catch
        error:badarg -> binary_to_atom(B, utf8)
    end.

validate_value(Name, Value, {vector, ElemType}, Defs, Opts) ->
    validate_vector(Name, Value, ElemType, Defs, Opts);
validate_value(Name, Value, {array, ElemType, Count}, Defs, Opts) ->
    validate_array(Name, Value, ElemType, Count, Defs, Opts);
validate_value(Name, Value, {union_type, UnionName}, Defs, _Opts) ->
    validate_union_type(Name, Value, UnionName, Defs);
validate_value(_Name, Value, {union_value, _UnionName}, _Defs, _Opts) when is_map(Value) ->
    [];
validate_value(Name, Value, {union_value, UnionName}, _Defs, _Opts) ->
    [{type_mismatch, Name, {union_value, UnionName}, Value}];
%% Strip default value wrapper and recurse
validate_value(Name, Value, {Type, _Default}, Defs, Opts) when is_atom(Type) ->
    validate_value(Name, Value, Type, Defs, Opts);
validate_value(Name, Value, Type, Defs, Opts) when is_atom(Type) ->
    case maps:get(Type, Defs, undefined) of
        #enum_def{values = Members} ->
            validate_enum(Name, Value, Members);
        #table_def{} ->
            case validate_table(Value, Type, Defs, Opts) of
                [] -> [];
                Errors -> [{nested_errors, Name, Errors}]
            end;
        #struct_def{fields = Fields} ->
            validate_struct(Name, Value, Fields);
        {struct, Fields} ->
            validate_struct(Name, Value, Fields);
        #union_def{} ->
            [{type_mismatch, Name, {union, Type}, Value}];
        undefined ->
            validate_scalar(Name, Value, Type)
    end.

validate_scalar(_Name, Value, bool) when is_boolean(Value) -> [];
validate_scalar(_Name, Value, byte) when is_integer(Value), Value >= -128, Value =< 127 -> [];
validate_scalar(_Name, Value, ubyte) when is_integer(Value), Value >= 0, Value =< 255 -> [];
validate_scalar(_Name, Value, short) when is_integer(Value), Value >= -32768, Value =< 32767 -> [];
validate_scalar(_Name, Value, ushort) when is_integer(Value), Value >= 0, Value =< 65535 -> [];
validate_scalar(_Name, Value, int) when
    is_integer(Value), Value >= -2147483648, Value =< 2147483647
->
    [];
validate_scalar(_Name, Value, uint) when is_integer(Value), Value >= 0, Value =< 4294967295 -> [];
validate_scalar(_Name, Value, long) when is_integer(Value) -> [];
validate_scalar(_Name, Value, ulong) when is_integer(Value), Value >= 0 -> [];
validate_scalar(_Name, Value, float) when is_number(Value) -> [];
validate_scalar(_Name, Value, double) when is_number(Value) -> [];
validate_scalar(_Name, Value, string) when is_binary(Value) -> [];
validate_scalar(_Name, Value, int8) when is_integer(Value), Value >= -128, Value =< 127 -> [];
validate_scalar(_Name, Value, uint8) when is_integer(Value), Value >= 0, Value =< 255 -> [];
validate_scalar(_Name, Value, int16) when is_integer(Value), Value >= -32768, Value =< 32767 -> [];
validate_scalar(_Name, Value, uint16) when is_integer(Value), Value >= 0, Value =< 65535 -> [];
validate_scalar(_Name, Value, int32) when
    is_integer(Value), Value >= -2147483648, Value =< 2147483647
->
    [];
validate_scalar(_Name, Value, uint32) when is_integer(Value), Value >= 0, Value =< 4294967295 -> [];
validate_scalar(_Name, Value, int64) when is_integer(Value) -> [];
validate_scalar(_Name, Value, uint64) when is_integer(Value), Value >= 0 -> [];
validate_scalar(_Name, Value, float32) when is_number(Value) -> [];
validate_scalar(_Name, Value, float64) when is_number(Value) -> [];
validate_scalar(Name, Value, Type) ->
    [{type_mismatch, Name, Type, Value}].

validate_enum(Name, Value, Members) when is_atom(Value) ->
    case lists:member(Value, Members) of
        true -> [];
        false -> [{invalid_enum, Name, Value, Members}]
    end;
validate_enum(Name, Value, Members) when is_binary(Value) ->
    try
        validate_enum(Name, binary_to_existing_atom(Value, utf8), Members)
    catch
        error:badarg -> [{invalid_enum, Name, Value, Members}]
    end;
validate_enum(Name, Value, Members) when is_integer(Value) ->
    case Value >= 0 andalso Value < length(Members) of
        true -> [];
        false -> [{invalid_enum, Name, Value, Members}]
    end;
validate_enum(Name, Value, Members) ->
    [{invalid_enum, Name, Value, Members}].

validate_vector(Name, Values, ElemType, Defs, Opts) when is_list(Values) ->
    {Errors, _} = lists:foldl(
        fun(Elem, {ErrAcc, Idx}) ->
            case validate_value(Name, Elem, ElemType, Defs, Opts) of
                [] -> {ErrAcc, Idx + 1};
                [Err | _] -> {[{invalid_vector_element, Name, Idx, Err} | ErrAcc], Idx + 1}
            end
        end,
        {[], 0},
        Values
    ),
    lists:reverse(Errors);
validate_vector(Name, Value, ElemType, _Defs, _Opts) ->
    [{type_mismatch, Name, {vector, ElemType}, Value}].

validate_array(Name, Values, ElemType, Count, Defs, Opts) when
    is_list(Values), length(Values) == Count
->
    {Errors, _} = lists:foldl(
        fun(Elem, {ErrAcc, Idx}) ->
            case validate_value(Name, Elem, ElemType, Defs, Opts) of
                [] -> {ErrAcc, Idx + 1};
                [Err | _] -> {[{invalid_array_element, Name, Idx, Err} | ErrAcc], Idx + 1}
            end
        end,
        {[], 0},
        Values
    ),
    lists:reverse(Errors);
validate_array(Name, Values, _ElemType, Count, _Defs, _Opts) when is_list(Values) ->
    [{array_length_mismatch, Name, Count, length(Values)}];
validate_array(Name, Value, ElemType, Count, _Defs, _Opts) ->
    [{type_mismatch, Name, {array, ElemType, Count}, Value}].

validate_union_type(Name, Value, UnionName, Defs) ->
    #union_def{members = Members} = maps:get(UnionName, Defs),
    MemberAtom =
        case Value of
            A when is_atom(A) -> A;
            B when is_binary(B) ->
                try
                    binary_to_existing_atom(B, utf8)
                catch
                    error:badarg -> B
                end;
            _ ->
                Value
        end,
    case lists:member(MemberAtom, Members) of
        true -> [];
        false -> [{invalid_union_type, Name, Value, Members}]
    end.

validate_struct(Name, Value, Fields) when is_map(Value) ->
    Errors = lists:flatmap(
        fun
            ({FieldName, FieldType}) ->
                case get_map_value(Value, FieldName) of
                    undefined -> [{missing_required, FieldName}];
                    FieldValue -> validate_scalar(FieldName, FieldValue, FieldType)
                end;
            ({FieldName, FieldType, _Attrs}) ->
                case get_map_value(Value, FieldName) of
                    undefined -> [{missing_required, FieldName}];
                    FieldValue -> validate_scalar(FieldName, FieldValue, FieldType)
                end
        end,
        Fields
    ),
    case Errors of
        [] -> [];
        _ -> [{nested_errors, Name, Errors}]
    end;
validate_struct(Name, Value, _Fields) ->
    [{type_mismatch, Name, struct, Value}].
