# DecFP interop (loaded when DecFP is): 1.x decoded DECIMAL columns to `Dec64`, so code
# that still holds `DecFP` values can bind them as parameters and load them with
# `MySQL.load`. Results decode to `MySQL.DecimalResult` regardless.
module MySQLDecFPExt

using MySQL, DecFP

MySQL.param_type(::DecFP.DecimalFloatingPoint) = return (MySQL.P.MYSQL_TYPE_STRING, false)
MySQL.encode_param_value!(buf::Vector{UInt8}, x::DecFP.DecimalFloatingPoint) = return (MySQL.P.write_lenenc_string!(buf, string(x)); nothing)

# The 1.x `MySQL.load` column types for the DecFP kinds.
MySQL.sqltype_nonmissing(::Type{DecFP.Dec64}) = return "NUMERIC(16, 6)"
MySQL.sqltype_nonmissing(::Type{DecFP.Dec128}) = return "NUMERIC(35, 6)"

end # module
