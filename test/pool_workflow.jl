# Public pool behavior on both real server families, using only disposable test databases.
function run_pool_workflow(admin)
    @testset "Scoped connection pool workflow" begin
        opts = admin.options
        query(conn, sql) = DBInterface.execute(conn, sql)
        scalar(conn, sql) = first(query(conn, sql))[1]
        database, other = "pool_review", "pool_review_other"
        query(admin, "CREATE DATABASE IF NOT EXISTS $database")
        query(admin, "CREATE DATABASE IF NOT EXISTS $other")
        query(admin, "DROP TABLE IF EXISTS $database.items")
        query(admin, "CREATE TABLE $database.items (id BIGINT PRIMARY KEY AUTO_INCREMENT, label VARCHAR(40))")
        pool = MySQL.ConnectionPool(opts.host, opts.user, opts.password;
            port=opts.port, db=database, limit=1, init_command="SET @pool_initialized=41",
            connect_timeout=10, read_timeout=10, write_timeout=10)
        identity = Ref{UInt32}()
        initial_isolation = Ref{String}()
        isolation = MySQL.server_kind(admin) == :mariadb ? "@@tx_isolation" : "@@transaction_isolation"
        stale = Ref{MySQL.Statement}()
        unfinished = Ref{MySQL.TextCursor{false}}()
        retained = nothing
        try
            retained = MySQL.with_connection(pool) do conn
                identity[] = MySQL.connection_id(conn)
                initial_isolation[] = String(scalar(conn, "SELECT $isolation"))
                @test scalar(conn, "SELECT DATABASE()") == database
                @test scalar(conn, "SELECT @pool_initialized") == 41
                insert = query(conn, "INSERT INTO items (label) VALUES ('kept')")
                @test scalar(conn, "SELECT LAST_INSERT_ID()") == DBInterface.lastrowid(insert)
                owned = query(conn, "SELECT 'owned across leases' AS value")
                query(conn, "CREATE TEMPORARY TABLE pool_temporary (id INT)")
                @test scalar(conn, "SELECT GET_LOCK('mysql_pool_review', 0)") == 1
                query(conn, "PREPARE pool_sql_statement FROM 'SELECT 43'")
                stale[] = DBInterface.prepare(conn, "SELECT 44")
                query(conn, "SET @pool_initialized=99, @pool_leaked=1")
                query(conn, "SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")
                query(conn, "SET autocommit=0")
                query(conn, "INSERT INTO items (label) VALUES ('rolled back')")
                query(conn, "USE $other")
                query(conn, "SET NAMES latin1")
                unfinished[] = DBInterface.execute(conn, "SELECT 1 UNION ALL SELECT 2"; mysql_store_result=false)
                @test first(first(unfinished[])) == 1
                owned
            end
            @test_throws MySQL.Protocol.ProtocolError iterate(unfinished[])
            @test scalar(admin, "SELECT IS_FREE_LOCK('mysql_pool_review')") == 1
            MySQL.with_connection(pool) do conn
                @test MySQL.connection_id(conn) == identity[]
                @test scalar(conn, "SELECT DATABASE()") == database
                @test scalar(conn, "SELECT @pool_initialized") == 41
                @test ismissing(scalar(conn, "SELECT @pool_leaked"))
                @test scalar(conn, "SELECT @@autocommit") == 1
                @test scalar(conn, "SELECT $isolation") == initial_isolation[]
                @test Tuple(first(query(conn, "SELECT @@character_set_client, @@character_set_connection, @@character_set_results"))) ==
                    ("utf8mb4", "utf8mb4", "utf8mb4")
                @test scalar(conn, "SELECT COUNT(*) FROM items WHERE label='rolled back'") == 0
                @test scalar(conn, "SELECT COUNT(*) FROM items WHERE label='kept'") == 1
                @test_throws MySQL.Error query(conn, "SELECT * FROM pool_temporary")
                @test_throws MySQL.Error query(conn, "EXECUTE pool_sql_statement")
                # Closing an old-generation Julia statement must not close a new server ID.
                current = DBInterface.prepare(conn, "SELECT 45")
                try
                    @test stale[].generation < current.generation
                    DBInterface.close!(stale[])
                    @test first(first(DBInterface.execute(current))) == 45
                finally
                    DBInterface.close!(current)
                end
                @test scalar(conn, "SELECT 'héllo 🐘'") == "héllo 🐘"
            end
            @test first(first(retained)) == "owned across leases"
            marker = ErrorException("pool callback failure")
            result = try
                MySQL.with_connection(pool) do conn
                    query(conn, "START TRANSACTION")
                    query(conn, "INSERT INTO items (label) VALUES ('callback error')")
                    throw(marker)
                end
            catch err
                err
            end
            @test result === marker
            @test pool.total == 0
            MySQL.with_connection(pool) do conn
                @test MySQL.connection_id(conn) != identity[]
                @test scalar(conn, "SELECT COUNT(*) FROM items WHERE label='callback error'") == 0
                @test scalar(conn, "SELECT @pool_initialized") == 41
                # The transaction helper works within the scoped session.
                DBInterface.transaction(conn) do
                    query(conn, "INSERT INTO items (label) VALUES ('transaction')")
                end
            end
            @test scalar(admin, "SELECT COUNT(*) FROM $database.items WHERE label='transaction'") == 1
        finally
            isassigned(stale) && DBInterface.close!(stale[])
            close(pool)
        end
        @test !isopen(pool) && pool.total == 0

        # With no configured database, unchanged sessions are reusable; USE requires retirement.
        no_database = MySQL.ConnectionPool(opts.host, opts.user, opts.password;
            port=opts.port, limit=1, connect_timeout=10, read_timeout=10, write_timeout=10)
        try
            a = MySQL.with_connection(no_database) do conn
                @test ismissing(scalar(conn, "SELECT DATABASE()"))
                MySQL.connection_id(conn)
            end
            b = MySQL.with_connection(MySQL.connection_id, no_database)
            @test a == b
            MySQL.with_connection(no_database) do conn
                query(conn, "USE $other")
            end
            @test no_database.total == 0
            MySQL.with_connection(no_database) do conn
                @test MySQL.connection_id(conn) != a
                @test ismissing(scalar(conn, "SELECT DATABASE()"))
            end
        finally
            close(no_database)
        end

        # Concurrent callers get distinct sessions and keep INSERT/LAST_INSERT_ID together.
        concurrent = MySQL.ConnectionPool(opts.host, opts.user, opts.password;
            port=opts.port, db=database, limit=2, connect_timeout=10, read_timeout=10, write_timeout=10)
        entered, proceed = Channel{UInt32}(2), Channel{Nothing}(2)
        jobs = [Threads.@spawn MySQL.with_connection(concurrent) do conn
            put!(entered, MySQL.connection_id(conn))
            take!(proceed)
            inserted = query(conn, "INSERT INTO items (label) VALUES ('concurrent')")
            last = scalar(conn, "SELECT LAST_INSERT_ID()")
            @test last == DBInterface.lastrowid(inserted)
            last
        end for _ in 1:2]
        try
            @test take!(entered) != take!(entered)
            put!(proceed, nothing)
            put!(proceed, nothing)
            @test fetch(jobs[1]) != fetch(jobs[2])
        finally
            close(concurrent)
        end
        query(admin, "DROP DATABASE $database")
        query(admin, "DROP DATABASE $other")
    end
end
