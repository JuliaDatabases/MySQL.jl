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

    @testset "A deadlock in a nested scope keeps the connection" begin
        DBInterface.execute(conn, "CREATE TABLE transaction_deadlock (id INT PRIMARY KEY, v INT) ENGINE=InnoDB")
        DBInterface.execute(conn, "CREATE TABLE transaction_deadlock_weight (id INT PRIMARY KEY) ENGINE=InnoDB")
        DBInterface.execute(conn, "INSERT INTO transaction_deadlock VALUES (1, 0), (2, 0)")
        o = conn.options
        db = only(Tables.columntable(DBInterface.execute(conn, "SELECT DATABASE() AS db")).db)
        peer = DBInterface.connect(MySQL.Connection, o.host, o.user, o.password; port=o.port, db=db)
        peer_holds_row2 = Base.Event()
        try
            # InnoDB rolls back the transaction that modified fewer rows: `conn`.
            peer_task = errormonitor(Threads.@spawn begin
                DBInterface.execute(peer, "START TRANSACTION")
                DBInterface.execute(peer, "INSERT INTO transaction_deadlock_weight VALUES " * join(("($i)" for i in 1:100), ","))
                DBInterface.execute(peer, "UPDATE transaction_deadlock SET v = v + 1 WHERE id = 2")
                notify(peer_holds_row2)
                DBInterface.execute(peer, "UPDATE transaction_deadlock SET v = v + 1 WHERE id = 1")
                DBInterface.execute(peer, "COMMIT")
            end)
            err = try
                DBInterface.transaction(conn) do
                    DBInterface.transaction(conn) do
                        DBInterface.execute(conn, "UPDATE transaction_deadlock SET v = v + 10 WHERE id = 1")
                        wait(peer_holds_row2)
                        DBInterface.execute(conn, "UPDATE transaction_deadlock SET v = v + 10 WHERE id = 2")
                    end
                end
            catch err
                err
            end
            wait(peer_task)
            @test err isa MySQL.Error && err.errno == 1213
            @test isopen(conn)
            @test conn.transaction_owner === nothing
            @test !MySQL.Protocol.in_transaction(MySQL.session(conn).status)
            @test collect(Tables.columntable(DBInterface.execute(conn, "SELECT v FROM transaction_deadlock ORDER BY id")).v) == [1, 1]
        finally
            DBInterface.close!(peer)
            DBInterface.execute(conn, "DROP TABLE transaction_deadlock")
            DBInterface.execute(conn, "DROP TABLE transaction_deadlock_weight")
        end
    end
end
