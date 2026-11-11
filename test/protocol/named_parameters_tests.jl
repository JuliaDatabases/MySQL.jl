# Named `:name` parameters (#207) against the fake peer: the client rewrites each `:name` to `?`
# outside literals and comments, and binds values by name. Uses the binary-protocol helpers
# from binary_tests.jl; the live-server checks are in test/user_workflow.jl.

rewrite(sql; no_backslash_escapes=false) = (r = N.named_sql(sql, no_backslash_escapes); r === nothing ? nothing : (r.sql, r.names))

@testset "named parameters: rewrite rules" begin
    unchanged = [
        "SELECT id FROM t WHERE id = ?",
        "SELECT @x := ?, @y:=1",
        "SELECT ':a', \":b\", `:c`",
        "SELECT TIME '10:30:00'",
        "SELECT 1 # :a\n",
        "SELECT 1 -- :a",
        "SELECT 1 /* :a */",
        "SELECT /*+ BKA(:a) */ 1",
        "SELECT 1 /*! , :a */",
        "SELECT 1 /*!80000 , :a */",
        "SELECT 1 /*M! , :a */",
        "SELECT :1",
        "SELECT 1:",
        "SELECT 'it''s :a'",
        "SELECT 'it\\'s :a'",
        "SELECT `a``:b`",
        "SELECT 'unterminated :a",
        "SELECT 1 /* unterminated :a",
    ]
    for sql in unchanged
        @test rewrite(sql) === nothing
    end
    rewritten = [
        "SELECT :a" => ("SELECT ?", [:a]),
        "INSERT INTO t VALUES (:id, :name)" => ("INSERT INTO t VALUES (?, ?)", [:id, :name]),
        "SELECT * FROM t WHERE a = :x OR b = :x" => ("SELECT * FROM t WHERE a = ? OR b = ?", [:x, :x]),
        "WHERE a=:userId AND b=:userid" => ("WHERE a=? AND b=?", [:userId, :userid]),
        "SELECT :_a1, :α" => ("SELECT ?, ?", [:_a1, :α]),
        "SET @v:=:val" => ("SET @v:=?", [:val]),
        "SELECT ':a', :b, \":c\", `:d`, :e" => ("SELECT ':a', ?, \":c\", `:d`, ?", [:b, :e]),
        "SELECT 'it''s', :a, 'x\\'y'" => ("SELECT 'it''s', ?, 'x\\'y'", [:a]),
        "SELECT 1--:a" => ("SELECT 1--?", [:a]),            # `--` without a space is two minus signs
        "SELECT 1 --\t:a\n, :b" => ("SELECT 1 --\t:a\n, ?", [:b]),
        "SELECT :a #:b\n, :c" => ("SELECT ? #:b\n, ?", [:a, :c]),
        "SELECT :a/*:b*/:c" => ("SELECT ?/*:b*/?", [:a, :c]),
        "SELECT /*!STRAIGHT_JOIN*/ a FROM t WHERE id = :id" => ("SELECT /*!STRAIGHT_JOIN*/ a FROM t WHERE id = ?", [:id]),
        "SELECT :a, 'x\\" => ("SELECT ?, 'x\\", [:a]),       # unterminated literal ending in a backslash
    ]
    for (sql, expected) in rewritten
        @test rewrite(sql) == expected
    end
    @test rewrite(SubString("xSELECT :a", 2)) == ("SELECT ?", [:a])
    # Under NO_BACKSLASH_ESCAPES a backslash is an ordinary character, so 'a\' ends the literal.
    @test rewrite("SELECT 'a\\', :b, 'c'"; no_backslash_escapes=true) == ("SELECT 'a\\', ?, 'c'", [:b])
    @test rewrite("SELECT \"a\\\", :b, \"c\""; no_backslash_escapes=true) == ("SELECT \"a\\\", ?, \"c\"", [:b])
    @test rewrite("SELECT 'a\\', :b, 'c'") === nothing
end

# The COM_STMT_EXECUTE parameter block after the 9-byte header.
param_block(payload) = payload[10:end]

@testset "named parameters: prepare and execute bind by name" begin
    sent = String[]
    payloads = Vector{UInt8}[]
    with_native(c -> begin
        push!(sent, expect_prepare(c)); send_prepare_ok(c, 1, 21, paramdefs(3), P.ColumnDef[])
        for _ in 1:4
            push!(payloads, expect_execute(c)); send_ok(c, 1; affected=1)
        end
        @test expect_stmt_close(c) == 21
        expect_query(c); send_ok(c, 1)
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t (a, b, c) VALUES (:id, :name, :id)")
        @test stmt.sql == "INSERT INTO t (a, b, c) VALUES (:id, :name, :id)"
        @test stmt.nparams == 3
        @test DBInterface.execute(stmt, (name="x", id=Int32(7), unused=1.5)).rows_affected == 1
        @test DBInterface.execute(stmt, Dict(:id => Int32(8), :name => "y")).rows_affected == 1
        @test DBInterface.execute(stmt, Dict("id" => Int32(9), "name" => "z")).rows_affected == 1
        @test DBInterface.execute(stmt, (Int32(10), "w", Int32(11))).rows_affected == 1   # one value per marker
        # Rejected before anything is sent: the peer sees COM_STMT_CLOSE next.
        err = try; DBInterface.execute(stmt, (id=Int32(1),)); nothing; catch e; e; end
        @test err isa MySQL.MySQLInterfaceError && occursin(":name", err.msg)
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt, (id=Int32(1), Name="case matters"))
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt, Tables.Row((id=Int32(1), name="x")))
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt, (Int32(1), "x"))
        @test_throws MySQL.MySQLInterfaceError DBInterface.execute(stmt)
        DBInterface.close!(stmt)
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 0
    end
    @test sent == ["INSERT INTO t (a, b, c) VALUES (?, ?, ?)"]
    expected = [(Int32(7), "x", Int32(7)), (Int32(8), "y", Int32(8)), (Int32(9), "z", Int32(9)), (Int32(10), "w", Int32(11))]
    for (i, (payload, values)) in enumerate(zip(payloads, expected))
        @test param_block(payload) == N.encode_param_block(values, N.param_signature(values), i == 1)
    end
end

@testset "named parameters: SQL without names is sent as written" begin
    sent = String[]
    payloads = Vector{UInt8}[]
    with_native(c -> begin
        push!(sent, expect_prepare(c)); send_prepare_ok(c, 1, 22, paramdefs(2), P.ColumnDef[])
        push!(payloads, expect_execute(c)); send_ok(c, 1)
        @test expect_stmt_close(c) == 22
        expect_query(c); send_ok(c, 1)
    end) do conn
        sql = "UPDATE t SET at = '10:30:00', v = @x := ? WHERE n = ? /* :a */"
        stmt = DBInterface.prepare(conn, sql)
        DBInterface.execute(stmt, (b=Int32(2), a="first"))   # a NamedTuple still binds in field order
        DBInterface.close!(stmt)
        DBInterface.execute(conn, "SELECT 1")
    end
    @test sent == ["UPDATE t SET at = '10:30:00', v = @x := ? WHERE n = ? /* :a */"]
    @test param_block(only(payloads)) == N.encode_param_block((Int32(2), "first"), N.param_signature((Int32(2), "first")), true)
end

@testset "named parameters: the session's NO_BACKSLASH_ESCAPES mode decides literal ends" begin
    sent = String[]
    with_native(c -> begin
        expect_query(c); send_ok(c, 1; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_NO_BACKSLASH_ESCAPES)
        push!(sent, expect_prepare(c)); send_prepare_ok(c, 1, 23, paramdefs(1), P.ColumnDef[])
        expect_query(c); send_ok(c, 1)
    end) do conn
        DBInterface.execute(conn, "SET sql_mode = 'NO_BACKSLASH_ESCAPES'")
        stmt = DBInterface.prepare(conn, "SELECT 'C:\\', :v")
        @test stmt.nparams == 1
        DBInterface.execute(conn, "SELECT 1")
    end
    @test sent == ["SELECT 'C:\\', ?"]
end

@testset "named parameters: ER_NEED_REPREPARE re-prepares the rewritten SQL" begin
    cols = [coldef("x"; type=P.MYSQL_TYPE_LONG, flags=NOT_NULL)]
    with_native(c -> begin
        @test expect_prepare(c) == "SELECT x FROM t WHERE x = ?"
        send_prepare_ok(c, 1, 24, paramdefs(1), cols)
        expect_execute(c); send_err(c, 1, P.ER_NEED_REPREPARE, "Prepared statement needs re-preparing")
        @test expect_prepare(c) == "SELECT x FROM t WHERE x = ?"
        send_prepare_ok(c, 1, 25, paramdefs(1), cols)
        @test expect_stmt_close(c) == 24
        expect_execute(c); send_resultset(c, 1, cols, [binary_row(Int32(5))])
    end) do conn
        stmt = DBInterface.prepare(conn, "SELECT x FROM t WHERE x = :x")
        @test Tables.columntable(DBInterface.execute(stmt, (x=Int32(5),))).x == Int32[5]
        DBInterface.close!(stmt)
    end
end

@testset "named parameters: the server decides when a :word is not a parameter" begin
    sent = String[]
    with_native(c -> begin
        # MariaDB prepares stored-program DDL; a label's `?` rewrite does not parse
        push!(sent, expect_prepare(c)); send_err(c, 1, P.ER_PARSE_ERROR, "near '? LEAVE'")
        push!(sent, expect_prepare(c)); send_prepare_ok(c, 1, 26, P.ColumnDef[], P.ColumnDef[])
        expect_execute(c); send_ok(c, 1)
        # `?` mixed with `:name`: the server counts both; the SQL as written does not parse
        push!(sent, expect_prepare(c)); send_prepare_ok(c, 1, 27, paramdefs(2), P.ColumnDef[])
        @test expect_stmt_close(c) == 27
        push!(sent, expect_prepare(c)); send_err(c, 1, P.ER_PARSE_ERROR, "near ':a'")
        # a typo: both attempts fail, and the rewrite's error is the one reported
        push!(sent, expect_prepare(c)); send_err(c, 1, P.ER_PARSE_ERROR, "near 'ORDR BY a'")
        push!(sent, expect_prepare(c)); send_err(c, 1, P.ER_PARSE_ERROR, "near ':a ORDR BY a'")
        # other errors are not retried
        push!(sent, expect_prepare(c)); send_err(c, 1, 1146, "Table 'x' doesn't exist")
        expect_query(c); send_ok(c, 1)
    end) do conn
        label = "CREATE PROCEDURE p() BEGIN lbl:LOOP LEAVE lbl; END LOOP; END"
        stmt = DBInterface.prepare(conn, label)
        @test stmt.nparams == 0
        @test DBInterface.execute(stmt).rows_affected == 0
        err = try; DBInterface.prepare(conn, "SELECT :a, ?"); nothing; catch e; e; end
        @test err isa MySQL.MySQLInterfaceError && occursin("cannot mix", err.msg)
        err = try; DBInterface.prepare(conn, "SELECT * FROM t WHERE a = :a ORDR BY a"); nothing; catch e; e; end
        @test err isa MySQL.StmtError && err.errno == P.ER_PARSE_ERROR && err.msg == "near 'ORDR BY a'"
        err = try; DBInterface.prepare(conn, "SELECT :a FROM x"); nothing; catch e; e; end
        @test err isa MySQL.StmtError && err.errno == 1146
        @test DBInterface.execute(conn, "SELECT 1").rows_affected == 0
    end
    @test sent == [
        "CREATE PROCEDURE p() BEGIN lbl? LEAVE lbl; END LOOP; END",
        "CREATE PROCEDURE p() BEGIN lbl:LOOP LEAVE lbl; END LOOP; END",
        "SELECT ?, ?",
        "SELECT :a, ?",
        "SELECT * FROM t WHERE a = ? ORDR BY a",
        "SELECT * FROM t WHERE a = :a ORDR BY a",
        "SELECT ? FROM x",
    ]
end

@testset "named parameters: executemany binds each NamedTuple row by name" begin
    seen = String[]
    payloads = Vector{UInt8}[]
    with_native(c -> begin
        expect_prepare(c); send_prepare_ok(c, 1, 28, paramdefs(2), P.ColumnDef[])
        push!(seen, expect_query(c)); send_ok(c, 1)                  # START TRANSACTION
        for _ in 1:2
            push!(payloads, expect_execute(c)); send_ok(c, 1; affected=1)
        end
        push!(seen, expect_query(c)); send_ok(c, 1)                  # COMMIT
    end) do conn
        stmt = DBInterface.prepare(conn, "INSERT INTO t (a, b) VALUES (:a, :b)")
        DBInterface.executemany(stmt, (b=["x", "y"], a=Int32[1, 2]))
        @test_throws DBInterface.ParameterError DBInterface.executemany(stmt, (a=Int32[1, 2], b=["x"]))
        DBInterface.close!(stmt)
    end
    @test seen == ["START TRANSACTION", "COMMIT"]
    @test param_block(payloads[1]) == N.encode_param_block((Int32(1), "x"), N.param_signature((Int32(1), "x")), true)
    @test param_block(payloads[2]) == N.encode_param_block((Int32(2), "y"), N.param_signature((Int32(2), "y")), false)
end
