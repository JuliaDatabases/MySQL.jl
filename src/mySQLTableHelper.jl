################################################################################
# Simple module to write a DataFrame into a mySql table in a fast and easy way.
#
# This module assume the table creation and support String, Int64, Float64,
# and Date data format and may be easily extended
#
# Usage mySQLTableHelper.createTable(DataFrame, TargetTableName::String, MySQL.Connection)
#
# Optional argument :
# - dropIfExist::Bool=true -> set to false if you want to append to an existing table
# - forceStringSize::Int64=-1 -> force to String size, if not set, size is automatically determined
# Usefull if you want to append multiple dataframe into a single table
#
# To avoid unicode integration problem, you should use the initCnxUtf8(MySQL.Connection) function
# before using the createTable function to properly intialize utf8 string format of the DB connection.
################################################################################

module mySQLTableHelper

    import Base.*

    using DataFrames, Dates, WeakRefStrings, MySQL, CSV

    export createTable, test

    mutable struct createTable

        df::DataFrame
        name::String
        cnx::MySQL.Connection
        dropIfExist::Bool
        forceStringSize::Int64
        fieldToCreate::Dict
        sqlCreate::String
        sqlBulkInsert::String
        warnings::DataFrame

        function createTable(df::DataFrame, name::String, cnx::MySQL.Connection;
                dropIfExist::Bool=true, forceStringSize::Int64=-1)
            ct = new(df, name, cnx, dropIfExist, forceStringSize)
            createTableQuerry(ct)
            bulkInsert(ct)
            return(ct)
        end

    end

    function bulkInsert(ct::createTable)

        #delete create the new table
        if ct.dropIfExist
            MySQL.execute!(ct.cnx, "DROP TABLE IF EXISTS " * ct.name * ";" )
            MySQL.execute!(ct.cnx, ct.sqlCreate)
        end

        #creation of a temp file for mass loading
        tempFile = replace(tempname(), "\\" => "/")
        if isfile(tempFile) rm(tempFile) end
        CSV.write(tempFile, ct.df)
        #println(tempFile)

        #Load the file into DB
        MySQL.execute!(ct.cnx, "LOAD DATA LOCAL INFILE '"  * tempFile * "' INTO TABLE " * ct.name *
            " CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' " *
            "OPTIONALLY ENCLOSED BY '\"' ESCAPED BY '\"' IGNORE 1 LINES;")

        #and delete of the file
        rm(tempFile)

    end

    #Build of the Create table querry
    function createTableQuerry(ct::createTable)

        ct.fieldToCreate = Dict()

        for n in names(ct.df)
            #println(n, " ",typeof(ct.df[n]))
            ct.fieldToCreate[n] = getSqlField(n, ct.df[!, n], ct)
        end

        sql = "CREATE TABLE " * ct.name * " ("

        for n in names(ct.df)
            sql = sql * " " * ct.fieldToCreate[n] * ", "
        end
        sql = sql[1:end-2] * ")"

        ct.sqlCreate = sql

    end

    getSqlField(name::Symbol, value::Array{Int64, 1}, ct::createTable)::String = escapeName(name) * " BIGINT"
    getSqlField(name::Symbol, value::Array{Union{Missing, Int64}, 1}, ct::createTable)::String = escapeName(name) * " BIGINT"

    getSqlField(name::Symbol, value::Array{Float64, 1}, ct::createTable)::String = escapeName(name) * " DOUBLE"
    getSqlField(name::Symbol, value::Array{Union{Missing, Float64}, 1}, ct::createTable)::String = escapeName(name) * " DOUBLE"

    getSqlField(name::Symbol, value::Array{Date, 1}, ct::createTable)::String = escapeName(name) * " DATE"
    getSqlField(name::Symbol, value::Array{Union{Missing, Date}, 1}, ct::createTable)::String = escapeName(name) * " DATE"

    getSqlField(name::Symbol, value::Array{Time, 1}, ct::createTable)::String = escapeName(name) * " DATE"
    getSqlField(name::Symbol, value::Array{Union{Missing, Time}, 1}, ct::createTable)::String = escapeName(name) * " DATE"

    getSqlField(name::Symbol, value::Array{DateTime, 1}, ct::createTable)::String = escapeName(name) * " DATE"
    getSqlField(name::Symbol, value::Array{Union{Missing, DateTime}, 1}, ct::createTable)::String = escapeName(name) * " DATE"

    getSqlFieldString(name::Symbol, value::Any, ct::createTable)::String =
        escapeName(name) * " VARCHAR(" * (ct.forceStringSize >= 0 ?
            string(ct.forceStringSize) :
            getMaxLength(value)) * ") DEFAULT ''"

    getSqlField(name::Symbol, value::Array{String, 1}, ct::createTable)::String = getSqlFieldString(name, value, ct)
    getSqlField(name::Symbol, value::Array{Missing, 1}, ct::createTable)::String = getSqlFieldString(name, value, ct)
    getSqlField(name::Symbol, value::WeakRefStrings.StringArray{String, 1}, ct::createTable)::String = getSqlFieldString(name, value, ct)
    getSqlField(name::Symbol, value::Array{Union{Missing, String},1}, ct::createTable)::String = getSqlFieldString(name, value, ct)

    escapeName(name::Symbol)::String = "`" * string(name) * "`"

    Base.length(x::Missing) = 0

    getMaxLength(tbl)::String = string(max(map(x->length(x), tbl)...))

    #Set the connextion to use utf8 string format
    function initCnxUtf8(cnx::MySQL.Connection)

        MySQL.execute!(cnx, "set character_set_client='utf8mb4';")
        MySQL.execute!(cnx, "set character_set_connection='utf8mb4';")
        MySQL.execute!(cnx, "set character_set_results='utf8mb4';")

        #return a dataset of the current parameters
        return(MySQL.Query(cnx, "SHOW SESSION VARIABLES LIKE 'character\\_set\\_%';") |> DataFrame)

    end

    function test(cnx::MySQL.Connection, testTableName::String)::Bool

        initCnxUtf8(cnx)

        dic = Dict()

        dic[:a] = 1
        dic[:b] = 1.0
        dic[:c] = "AéàèàB"
        dic[:d] = Date(2020,12,31)

        df = DataFrame()
        map(x->df[!, x] = [dic[x]], collect(keys(dic)))

        createTable(df, testTableName, cnx)

        df = missing
        df = MySQL.Query(cnx, "SELECT * FROM " * testTableName * ";") |> DataFrame

        return mapreduce(x -> df[1, x] == dic[x], &, keys(dic))

    end

end
