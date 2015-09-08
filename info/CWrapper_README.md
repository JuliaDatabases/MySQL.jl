MySQL.jl
========

An interface to MySQL from Julia. Uses the C MySQL API and obeys the [DBI.jl protocol](https://github.com/johnmyleswhite/DBI.jl).

# Usage Example

    using DBI
    using MySQL

    db = connect(MySQL5, "127.0.0.1", "username", "password", "dbname")

    sql = "CREATE TABLE users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(255))"

    stmt = prepare(db, sql)
    execute(stmt)

    try
        stmt = prepare(db, sql)
        execute(stmt)
    end

    errcode(db)
    errstring(db)

    rowid = lastinsertid(db)

    stmt = prepare(db, "INSERT INTO users (name) VALUES ('Jeff Bezanson')")
    execute(stmt)

    stmt = prepare(db, "INSERT INTO users (name) VALUES ('Viral Shah')")
    execute(stmt)

    stmt = prepare(db, "INSERT INTO users (name) VALUES ('Stefan Karpinski')")
    execute(stmt)

    rowid = lastinsertid(db)

    stmt = prepare(db, "DROP TABLE users")
    execute(stmt)

    disconnect(db)


# Systems

* Works on OS X
