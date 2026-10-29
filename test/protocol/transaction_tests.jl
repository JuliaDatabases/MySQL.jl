@testset "Transaction scope failures and ownership" begin
    in_trans = P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_STATUS_IN_TRANS
    marker = ErrorException("callback failed")

    @testset "Savepoint creation failure leaves caller transaction intact" begin
        with_native(c -> begin
            @test expect_query(c) == "START TRANSACTION"
            send_ok(c, 1; status=in_trans)
            @test startswith(expect_query(c), "SAVEPOINT _mysqljl_")
            send_err(c, 1, 1205, "savepoint failed")
            @test expect_query(c) == "ROLLBACK"
            send_ok(c, 1)
        end) do conn
            DBInterface.execute(conn, "START TRANSACTION")
            called = Ref(false)
            err = try
                DBInterface.transaction(conn) do
                    called[] = true
                end
            catch err
                err
            end
            @test err isa MySQL.Error && err.errno == 1205
            @test !called[]
            @test conn.transaction_owner === nothing
            @test isopen(conn)
            DBInterface.execute(conn, "ROLLBACK")
        end
    end

    for nested in (false, true), cleanup in (:rollback, :release)
        !nested && cleanup === :release && continue
        @testset "Failed $cleanup in nested=$nested closes the uncertain session" begin
            with_native(c -> begin
                @test expect_query(c) == "START TRANSACTION"
                send_ok(c, 1; status=in_trans)
                name = if nested
                    sql = expect_query(c)
                    @test startswith(sql, "SAVEPOINT _mysqljl_")
                    send_ok(c, 1; status=in_trans)
                    split(sql)[2]
                else
                    nothing
                end
                @test expect_query(c) == (nested ? "ROLLBACK TO SAVEPOINT $name" : "ROLLBACK")
                if cleanup === :release
                    send_ok(c, 1; status=in_trans)
                    @test expect_query(c) == "RELEASE SAVEPOINT $name"
                end
                send_err(c, 1, 1181, "cleanup failed")
            end) do conn
                nested && DBInterface.execute(conn, "START TRANSACTION")
                err = try
                    DBInterface.transaction(() -> throw(marker), conn)
                catch err
                    err
                end
                @test err isa CompositeException
                if err isa CompositeException
                    @test length(err.exceptions) == 2
                    @test err.exceptions[1] === marker
                    @test err.exceptions[2] isa MySQL.Error
                    @test err.exceptions[2].errno == 1181
                end
                @test !isopen(conn)
                @test conn.transaction_owner === nothing
                @test_throws ErrorException MySQL.ping(conn)
            end
        end
    end

    # A deadlock rolls back the whole transaction on the server, savepoints included.
    for outer in (:sql, :helper)
        @testset "Savepoint discarded by a deadlock keeps the session (outer=$outer)" begin
            with_native(c -> begin
                @test expect_query(c) == "START TRANSACTION"
                send_ok(c, 1; status=in_trans)
                sql = expect_query(c)
                @test startswith(sql, "SAVEPOINT _mysqljl_")
                send_ok(c, 1; status=in_trans)
                @test expect_query(c) == "UPDATE t SET v = 1"
                send_err(c, 1, 1213, "Deadlock found when trying to get lock"; sqlstate="40001")
                @test expect_query(c) == "ROLLBACK TO SAVEPOINT $(split(sql)[2])"
                send_err(c, 1, 1305, "SAVEPOINT does not exist"; sqlstate="42000")
                if outer === :helper
                    @test expect_query(c) == "ROLLBACK"
                    send_ok(c, 1)
                end
                _, cmd, _ = read_command(c)
                @test cmd == P.COM_PING
                send_ok(c, 1)
            end) do conn
                inner() = DBInterface.transaction(() -> DBInterface.execute(conn, "UPDATE t SET v = 1"), conn)
                err = try
                    if outer === :sql
                        DBInterface.execute(conn, "START TRANSACTION")
                        inner()
                    else
                        DBInterface.transaction(inner, conn)
                    end
                catch err
                    err
                end
                @test err isa MySQL.Error && err.errno == 1213
                @test isopen(conn)
                @test conn.transaction_owner === nothing
                @test MySQL.ping(conn)
            end
        end
    end

    @testset "Failed commit retains its error after successful rollback" begin
        with_native(c -> begin
            @test expect_query(c) == "START TRANSACTION"
            send_ok(c, 1; status=in_trans)
            @test expect_query(c) == "COMMIT"
            send_err(c, 1, 1205, "commit failed")
            @test expect_query(c) == "ROLLBACK"
            send_ok(c, 1)
            _, cmd, _ = read_command(c)
            @test cmd == P.COM_PING
            send_ok(c, 1)
        end) do conn
            err = try
                DBInterface.transaction(() -> :value, conn)
            catch err
                err
            end
            @test err isa MySQL.Error && err.errno == 1205
            @test conn.transaction_owner === nothing
            @test MySQL.ping(conn)
        end
    end

    @testset "Ended outer scope cannot run another callback" begin
        with_native(c -> begin
            @test expect_query(c) == "START TRANSACTION"
            send_ok(c, 1; status=in_trans)
            @test expect_query(c) == "COMMIT"
            send_ok(c, 1)
            @test expect_query(c) == "COMMIT"
            send_ok(c, 1)
        end) do conn
            called = Ref(false)
            DBInterface.transaction(conn) do
                DBInterface.execute(conn, "COMMIT")
                @test_throws MySQL.MySQLInterfaceError DBInterface.transaction(conn) do
                    called[] = true
                end
                @test !called[]
                @test conn.transaction_owner === current_task()
            end
            @test conn.transaction_owner === nothing
        end
    end

    @testset "Pending response is drained before choosing a scope" begin
        with_native(c -> begin
            @test expect_query(c) == "START TRANSACTION"
            send_ok(c, 1; status=in_trans)
            @test expect_query(c) == "SELECT 1"
            send_resultset(c, 1, [coldef("n"; type=P.MYSQL_TYPE_LONG)], [UInt8[0x01, 0x31]];
                status=P.SERVER_STATUS_AUTOCOMMIT)
            # The previous terminator ended the transaction; don't use a stale savepoint.
            @test expect_query(c) == "START TRANSACTION"
            send_ok(c, 1; status=in_trans)
            @test expect_query(c) == "COMMIT"
            send_ok(c, 1)
        end) do conn
            DBInterface.execute(conn, "START TRANSACTION")
            cursor = DBInterface.execute(conn, "SELECT 1"; mysql_store_result=false)
            @test P.in_transaction(MySQL.session(conn).status)
            @test DBInterface.transaction(() -> 19, conn) == 19
            @test_throws P.ProtocolError iterate(cursor)
        end
    end

    @testset "COMMIT lost after it was written (#248)" begin
        # The transaction may have committed: the COMMIT reports 2013, the ROLLBACK that
        # follows is refused before it is written (2006), and the connection is closed.
        with_server(conn -> plain_peer_connect!(conn; caps=MYSQL8_SERVER_CAPS & ~P.CLIENT_SSL, after=c -> begin
            @test expect_query(c) == "START TRANSACTION"
            send_ok(c, 1; status=in_trans)
            @test expect_query(c) == "INSERT 1"
            send_ok(c, 1; affected=1, status=in_trans)
            @test expect_query(c) == "COMMIT"
        end)) do port
            conn = DBInterface.connect(N.Connection, "127.0.0.1", "root", "pw"; port=port, ssl_mode=:disabled, connect_timeout=10)
            err = try; DBInterface.transaction(() -> DBInterface.execute(conn, "INSERT 1"), conn); nothing; catch e; e; end
            @test err isa CompositeException
            if err isa CompositeException
                @test length(err.exceptions) == 2
                commit_err, rollback_err = err.exceptions
                @test commit_err isa MySQL.Error && commit_err.errno == P.CR_SERVER_LOST
                @test rollback_err isa MySQL.Error && rollback_err.errno == P.CR_SERVER_GONE_ERROR
            end
            @test !isopen(conn)
        end
    end
end
