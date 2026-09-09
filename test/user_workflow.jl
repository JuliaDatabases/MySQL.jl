# Shared end-to-end API check, run on both live server lanes.
function run_user_workflow(conn)
    @testset "DBInterface and Tables user workflow" begin
        DBInterface.execute(conn, "CREATE DATABASE IF NOT EXISTS workflow_review")
        DBInterface.execute(conn, "USE workflow_review")
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
