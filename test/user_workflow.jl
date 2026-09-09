# Shared end-to-end API check, run on both live server lanes.
function run_user_workflow(conn)
    @testset "DBInterface and Tables user workflow" begin
        DBInterface.execute(conn, "CREATE DATABASE IF NOT EXISTS workflow_review")
        DBInterface.execute(conn, "USE workflow_review")
        # #236: exercise the old 33-parameter crash and the native sequence wrap.
        for n in (33, 260)
            stmt = DBInterface.prepare(conn, "SELECT " * join(fill("?", n), ","))
            try
                @test Tuple(first(DBInterface.execute(stmt, fill(UInt64(7), n)))) == Tuple(fill(UInt64(7), n))
            finally
                DBInterface.close!(stmt)
            end
        end
        stmt = DBInterface.prepare(conn, "SELECT ?, ?")
        try
            for params in ((7, "test"), (id=7, uname="test"), Any[7, "test"],
                    first(Tables.rows((id=[7], uname=["test"]))), Tables.Row((id=7, uname="test")))
                # NamedTuple and Tables rows bind by field order. #208 also needs
                # nonnumeric strings to remain strings on MariaDB 11.
                @test Tuple(first(DBInterface.execute(stmt, params))) == (7, "test")
            end
        finally
            DBInterface.close!(stmt)
        end
        # A fresh statement per type: MySQL can retain inferred parameter types.
        for param in (17, "test", missing, nothing, Date(2026, 1, 1), DateTime(2026, 1, 1), Time(1, 2, 3))
            @test isequal(first(DBInterface.execute(conn, "SELECT ?", param))[1], param === nothing ? missing : param)
        end
        # #206: a buffered row owns its bytes across later commands.
        retained = first(DBInterface.execute(conn, "SELECT 'Street 1' AS description"))
        DBInterface.execute(conn, "SELECT 'Roni' AS name")
        @test retained.description == "Street 1"
        # #209: the INSERT column list must follow the source names.
        DBInterface.execute(conn, "DROP TABLE IF EXISTS named_load")
        MySQL.load((x=[1], y=[2]), conn, "named_load")
        MySQL.load((y=[3], x=[4]), conn, "named_load")
        @test Tables.columntable(DBInterface.execute(conn, "SELECT * FROM named_load ORDER BY x")) == (x=[1, 4], y=[2, 3])
        @test_throws MySQL.StmtError MySQL.load((foo=[5], bar=[6]), conn, "named_load")
        DBInterface.executemany(conn, "INSERT INTO named_load (x, y) VALUES (?, ?)", (x=[7, 9], y=[8, 10]))
        @test Tables.columntable(DBInterface.execute(conn, "SELECT * FROM named_load WHERE x > 4 ORDER BY x")) == (x=[7, 9], y=[8, 10])
        DBInterface.execute(conn, "DROP TABLE IF EXISTS items")
        DBInterface.execute(conn, "CREATE TABLE items (id BIGINT PRIMARY KEY, label VARCHAR(100), amount DECIMAL(30,6), stamp DATETIME(6), data BLOB)")
        stmt = DBInterface.prepare(conn, "INSERT INTO items VALUES (?, ?, ?, ?, ?)")
        try
            @test DBInterface.execute(stmt, (1, "one", "12.345678", DateTime(2026, 1, 2), UInt8[0, 255])).rows_affected == 1
            DBInterface.executemany(stmt, ([2, 3], ["two", "three"], ["2.000001", "3.000002"], fill(DateTime(2026, 1, 3), 2), [UInt8[2], UInt8[3]]))
        finally
            DBInterface.close!(stmt)
        end
        expected = Tables.columntable(DBInterface.execute(conn, "SELECT * FROM items ORDER BY id"))
        @test expected.id == [1, 2, 3]
        @test expected.data == [UInt8[0, 255], UInt8[2], UInt8[3]]
        @test Tables.columntable(DBInterface.execute(conn, "SELECT * FROM items ORDER BY id"; mysql_store_result=false)) == expected
        @test Tables.columntable(DBInterface.execute(conn, "SELECT * FROM items WHERE id > ? ORDER BY id", (0,))) == expected
        @test DBInterface.transaction(conn) do
            DBInterface.execute(conn, "UPDATE items SET label='changed' WHERE id=1")
            :committed
        end == :committed
        @test_throws ErrorException DBInterface.transaction(conn) do
            DBInterface.execute(conn, "DELETE FROM items")
            error("rollback workflow")
        end
        @test only(Tables.columntable(DBInterface.execute(conn, "SELECT COUNT(*) AS n FROM items")).n) == 3
        @test_throws MySQL.StmtError DBInterface.execute(conn, "INSERT INTO items (id) VALUES (?)", (1,))
        @test MySQL.ping(conn)

        # Five columns cross the old 4096-parameter failure at the default batch size.
        source = (id=collect(1:1005), label=fill("loaded", 1005), amount=fill("1.250000", 1005), stamp=fill(DateTime(2026, 1, 2), 1005), data=fill(UInt8[42], 1005))
        DBInterface.execute(conn, "DROP TABLE IF EXISTS loaded")
        @test MySQL.load(source, conn, "loaded"; coltypes=Dict(:amount => "DECIMAL(30,6)")) == "`loaded`"
        actual = Tables.columntable(DBInterface.execute(conn, "SELECT * FROM loaded ORDER BY id"; mysql_store_result=false))
        @test actual.id == source.id
        @test actual.label == source.label
        @test actual.data == source.data
        @test actual.stamp == source.stamp

        DBInterface.execute(conn, "DROP PROCEDURE IF EXISTS workflow_results")
        DBInterface.execute(conn, "CREATE PROCEDURE workflow_results() BEGIN SELECT 1 AS first_result; SELECT 'two' AS second_result; END")
        results = [Tables.columntable(c) for c in DBInterface.executemultiple(conn, "CALL workflow_results()")]
        @test results[1] == (first_result=[1],)
        @test results[2] == (second_result=["two"],)
        @test length(results) == 3 # CALL has a final status result.
        @test MySQL.ping(conn)
        DBInterface.execute(conn, "DROP PROCEDURE workflow_results")
    end
end
