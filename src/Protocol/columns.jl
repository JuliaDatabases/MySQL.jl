"""
    ColumnDef

Protocol::ColumnDefinition41. `length` is the declared maximum display length, `type` an
`enum_field_types` byte, `flags` the column definition flags, `charset` the collation id.
"""
struct ColumnDef
    catalog::String
    schema::String
    table::String
    org_table::String
    name::String
    org_name::String
    charset::UInt16
    length::UInt32
    type::UInt8
    flags::UInt16
    decimals::UInt8
end

const COLUMN_DEF_FIXED_FIELDS_LENGTH = 0x0C

"""
    parse_column_def(p::PacketView; extended_metadata=false) -> ColumnDef

`extended_metadata=true` only when `MARIADB_CLIENT_EXTENDED_METADATA` was negotiated (it is
never requested in 2.0); then a `string<lenenc>` of extended type information precedes the
fixed-length block and is skipped.
"""
function parse_column_def(p::PacketView; extended_metadata::Bool=false)
    c = PacketCursor(p)
    catalog = read_lenenc_string!(c, "catalog")
    schema = read_lenenc_string!(c, "schema")
    table = read_lenenc_string!(c, "table")
    org_table = read_lenenc_string!(c, "org_table")
    name = read_lenenc_string!(c, "name")
    org_name = read_lenenc_string!(c, "org_name")
    extended_metadata && read_lenenc_window!(c, "extended metadata")
    fixed = read_lenenc_length!(c, "fixed-length fields")
    fixed == COLUMN_DEF_FIXED_FIELDS_LENGTH || protocol_error("malformed column definition: fixed-length block of $fixed bytes (expected 12)")
    charset = read_u16!(c)
    length = read_u32!(c)
    type = read_u8!(c)
    flags = read_u16!(c)
    decimals = read_u8!(c)
    skip!(c, 2, "column definition reserved bytes")
    atend(c) || protocol_error("malformed column definition: $(remaining(c)) trailing bytes")
    return ColumnDef(catalog, schema, table, org_table, name, org_name, charset, length, type, flags, decimals)
end

has_flag(def::ColumnDef, flag::UInt16) = return (def.flags & flag) != 0
is_not_null(def::ColumnDef) = return has_flag(def, NOT_NULL_FLAG)
# `NUM_FLAG` is not sent on the wire: libmysqlclient sets it client-side for the numeric
# wire types (`IS_NUM` in mysql_com.h), and that is what the 1.x type mapping observed. A
# wire-supplied NUM_FLAG is not trusted either — the unsigned mapping applies only to wire
# types whose Julia type has an unsigned counterpart (`MYSQL_TYPE_NULL` maps to `String`),
# so a malicious column definition cannot reach `unsigned(String)`.
function is_numeric_type(type::UInt8)
    (type <= MYSQL_TYPE_INT24 && type != MYSQL_TYPE_TIMESTAMP && type != MYSQL_TYPE_NULL) && return true
    return type == MYSQL_TYPE_YEAR || type == MYSQL_TYPE_NEWDECIMAL
end

is_unsigned(def::ColumnDef) = return has_flag(def, UNSIGNED_FLAG) && is_numeric_type(def.type)
is_binary(def::ColumnDef) = return has_flag(def, BINARY_FLAG)
is_blob(def::ColumnDef) = return has_flag(def, BLOB_FLAG)

const FIELD_TYPE_NAMES = Dict{UInt8, String}(
    MYSQL_TYPE_DECIMAL => "DECIMAL", MYSQL_TYPE_TINY => "TINY", MYSQL_TYPE_SHORT => "SHORT",
    MYSQL_TYPE_LONG => "LONG", MYSQL_TYPE_FLOAT => "FLOAT", MYSQL_TYPE_DOUBLE => "DOUBLE",
    MYSQL_TYPE_NULL => "NULL", MYSQL_TYPE_TIMESTAMP => "TIMESTAMP", MYSQL_TYPE_LONGLONG => "LONGLONG",
    MYSQL_TYPE_INT24 => "INT24", MYSQL_TYPE_DATE => "DATE", MYSQL_TYPE_TIME => "TIME",
    MYSQL_TYPE_DATETIME => "DATETIME", MYSQL_TYPE_YEAR => "YEAR", MYSQL_TYPE_NEWDATE => "NEWDATE",
    MYSQL_TYPE_VARCHAR => "VARCHAR", MYSQL_TYPE_BIT => "BIT", MYSQL_TYPE_JSON => "JSON",
    MYSQL_TYPE_NEWDECIMAL => "NEWDECIMAL", MYSQL_TYPE_ENUM => "ENUM", MYSQL_TYPE_SET => "SET",
    MYSQL_TYPE_TINY_BLOB => "TINY_BLOB", MYSQL_TYPE_MEDIUM_BLOB => "MEDIUM_BLOB",
    MYSQL_TYPE_LONG_BLOB => "LONG_BLOB", MYSQL_TYPE_BLOB => "BLOB", MYSQL_TYPE_VAR_STRING => "VAR_STRING",
    MYSQL_TYPE_STRING => "STRING", MYSQL_TYPE_GEOMETRY => "GEOMETRY",
)

field_type_name(type::UInt8) = return get(() -> "type$(Int(type))", FIELD_TYPE_NAMES, type)

function Base.show(io::IO, def::ColumnDef)
    print(io, "ColumnDef(", repr(def.name), " ", field_type_name(def.type), " charset=", def.charset, " len=", def.length, " flags=0x", string(def.flags, base=16, pad=4), ")")
    return nothing
end
