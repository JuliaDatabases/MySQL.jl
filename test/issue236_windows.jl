if get(ENV, "MYSQLJL_BOOTSTRAPPED", "false") != "true"
    using Pkg

    jll_pkg_version(v::String) = VersionNumber(occursin("+", v) ? v : string(v, "+0"))

    Pkg.activate(; temp=true)
    Pkg.develop(PackageSpec(path=dirname(@__DIR__)))
    Pkg.add([
        PackageSpec(name="DBInterface"),
        PackageSpec(name="Tables"),
    ])

    jll_version = get(ENV, "MYSQLJL_JLL_VERSION", "default")
    if jll_version != "default"
        Pkg.add(PackageSpec(name="MariaDB_Connector_C_jll", version=jll_pkg_version(jll_version)))
    else
        Pkg.add(PackageSpec(name="MariaDB_Connector_C_jll"))
    end

    Pkg.instantiate()
    Pkg.status()

    ENV["MYSQLJL_BOOTSTRAPPED"] = "true"
    include(@__FILE__)
    exit()
end

using DBInterface
using Libdl
using MariaDB_Connector_C_jll
using MySQL
using Random
using Tables

function logline(xs...)
    println(xs...)
    flush(stdout)
    return nothing
end

function connect_root(; db=nothing)
    host = get(ENV, "MYSQLJL_HOST", "127.0.0.1")
    port = parse(Int, get(ENV, "MYSQLJL_PORT", "3306"))
    user = get(ENV, "MYSQLJL_USER", "root")
    password = get(ENV, "MYSQLJL_PASSWORD", "root")

    if db === nothing
        return DBInterface.connect(MySQL.Connection, host, user, password; port=port, connect_timeout=10)
    else
        return DBInterface.connect(MySQL.Connection, host, user, password; db=db, port=port, connect_timeout=10)
    end
end

function wait_for_connection(; db=nothing, timeout=30.0)
    start = time()
    last_err = nothing
    while time() - start < timeout
        try
            return connect_root(; db=db)
        catch err
            last_err = err
            logline("WAIT_CONNECTION db=", db, " error=", sprint(showerror, err))
            sleep(1)
        end
    end
    error("MySQL did not become ready: ", sprint(showerror, last_err))
end

function placeholders(n::Integer)
    return join(fill("?", n), ",")
end

function query_for(shape::Symbol, n::Integer)
    marks = placeholders(n)
    if shape === :table
        return "SELECT id FROM myTable WHERE id IN ($marks)"
    elseif shape === :constant
        return "SELECT 1 AS id WHERE 1 IN ($marks)"
    elseif shape === :echo
        return "SELECT $marks"
    else
        error("unknown query shape: $shape")
    end
end

function consume(cursor)
    rows = 0
    for _ in cursor
        rows += 1
    end
    return rows
end

function run_case(conn, name::String, shape::Symbol, params; mysql_store_result::Bool=true)
    n = length(params)
    query = query_for(shape, n)
    logline("BEGIN name=", name,
            " shape=", shape,
            " n=", n,
            " eltype=", eltype(params),
            " mysql_store_result=", mysql_store_result)
    logline("QUERY ", query)
    logline("FIRST_VALUES ", collect(Iterators.take(params, min(n, 5))))

    stmt = DBInterface.prepare(conn, query)
    logline("PREPARED nparams=", stmt.nparams, " nfields=", stmt.nfields)

    cursor = DBInterface.execute(stmt, params; mysql_store_result=mysql_store_result)
    rows = consume(cursor)
    logline("DONE name=", name, " rows=", rows)

    DBInterface.close!(stmt)
    return nothing
end

function prepare_database()
    conn = wait_for_connection()
    try
        version = DBInterface.execute(conn, "SELECT VERSION() AS version") |> Tables.columntable
        logline("SERVER_VERSION ", only(version.version))

        DBInterface.execute(conn, "DROP DATABASE IF EXISTS issue236")
        DBInterface.execute(conn, "CREATE DATABASE issue236")
    finally
        DBInterface.close!(conn)
    end

    conn = wait_for_connection(db="issue236")
    DBInterface.execute(conn, "CREATE TABLE myTable (id BIGINT UNSIGNED NOT NULL PRIMARY KEY)")

    stmt = DBInterface.prepare(conn, "INSERT INTO myTable (id) VALUES (?)")
    try
        for id in UInt64(1):UInt64(512)
            DBInterface.execute(stmt, id)
        end
    finally
        DBInterface.close!(stmt)
    end
    return conn
end

function main()
    logline("JULIA_VERSION ", VERSION)
    logline("OS ", Sys.KERNEL, " MACHINE ", Sys.MACHINE)
    logline("WORD_SIZE ", Sys.WORD_SIZE)
    logline("LIBMARIADB ", MariaDB_Connector_C_jll.libmariadb)
    logline("LIBMARIADB_HANDLE ", Libdl.dlopen_e(MariaDB_Connector_C_jll.libmariadb))

    conn = prepare_database()
    try
        Random.seed!(0x236)

        for n in (31, 32, 33, 34, 64, 128)
            run_case(conn, "table-small-uint64", :table, UInt64.(1:n))
        end

        for n in (32, 33, 34)
            run_case(conn, "table-small-int64", :table, Int64.(1:n))
            run_case(conn, "table-random-uint64", :table, rand(UInt64, n))
            run_case(conn, "constant-small-uint64", :constant, UInt64.(1:n))
            run_case(conn, "table-small-uint64-unbuffered", :table, UInt64.(1:n); mysql_store_result=false)
        end

        run_case(conn, "echo-small-uint64", :echo, UInt64.(1:33))
    finally
        DBInterface.close!(conn)
    end

    logline("ISSUE236_DIAGNOSTIC_COMPLETE")
end

main()
