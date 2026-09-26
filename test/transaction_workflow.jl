function run_transaction_workflow(conn)
    @testset "Transaction scopes preserve enclosing work" begin
        DBInterface.execute(conn, "CREATE TEMPORARY TABLE transaction_scopes (id INT PRIMARY KEY) ENGINE=InnoDB")
        ids() = collect(Tables.columntable(DBInterface.execute(conn, "SELECT id FROM transaction_scopes ORDER BY id")).id)
        clear() = DBInterface.execute(conn, "DELETE FROM transaction_scopes")
        marker = ErrorException("transaction callback failed")
        try
            for fail in (false, true)
                clear()
                DBInterface.execute(conn, "START TRANSACTION")
                DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (1)")
                result = try
                    DBInterface.transaction(conn) do
                        DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (2)")
                        fail && throw(marker)
                        :result
                    end
                catch err
                    err
                end
                @test result === (fail ? marker : :result)
                @test ids() == (fail ? [1] : [1, 2])
                @test MySQL.Protocol.in_transaction(MySQL.session(conn).status)
                @test conn.transaction_owner === nothing
                DBInterface.execute(conn, "ROLLBACK")
                @test isempty(ids())
            end

            @test DBInterface.transaction(conn) do
                DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (1)")
                result = try
                    DBInterface.transaction(conn) do
                        DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (2)")
                        @test DBInterface.transaction(() -> 17, conn) == 17
                        throw(marker)
                    end
                catch err
                    err
                end
                @test result === marker
                @test conn.transaction_owner === current_task()
                @test ids() == [1]
                DBInterface.transaction(conn) do
                    DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (3)")
                end
                :outer_result
            end === :outer_result
            @test ids() == [1, 3]
            @test conn.transaction_owner === nothing

            clear()
            stmt = DBInterface.prepare(conn, "INSERT INTO transaction_scopes VALUES (?)")
            try
                @test DBInterface.transaction(conn) do
                    DBInterface.execute(stmt, (1,))
                    @test_throws MySQL.StmtError DBInterface.executemany(stmt, ([2, 2],))
                    @test ids() == [1]
                    @test DBInterface.executemany(stmt, ([3, 4],)) === nothing
                    :batch_result
                end === :batch_result
                @test ids() == [1, 3, 4]
                @test_throws ErrorException DBInterface.transaction(conn) do
                    DBInterface.executemany(stmt, ([5, 6],))
                    throw(marker)
                end
                @test ids() == [1, 3, 4]
            finally
                DBInterface.close!(stmt)
            end

            clear()
            DBInterface.execute(conn, "SET autocommit=0")
            try
                DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (7)")
                @test DBInterface.transaction(conn) do
                    DBInterface.execute(conn, "INSERT INTO transaction_scopes VALUES (8)")
                    :implicit_outer
                end === :implicit_outer
                DBInterface.execute(conn, "ROLLBACK")
                @test isempty(ids())
            finally
                DBInterface.execute(conn, "ROLLBACK")
                DBInterface.execute(conn, "SET autocommit=1")
            end
            @test MySQL.ping(conn)
        finally
            DBInterface.execute(conn, "DROP TEMPORARY TABLE transaction_scopes")
        end
    end
end
