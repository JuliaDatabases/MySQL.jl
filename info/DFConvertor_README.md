MySQL.jl
======

The MySQL.jl package is meant to provide a database-independent API that all database drivers can be expected to comply with. This makes it easy to write code that can be easily ported between different databases. 

# Types

* `DatabaseSystem`: This represents a specific type of database, like:
    * `MySQL`
* `DatabaseHandle`: This represents an established connection to a database
* `StatementHandle`: This represents a prepared SQL statement ready for execution in the database
* `DatabaseTable`: Metadata about a database table and its columns
* `DatabaseColumn`: Metadata about a database column

# Functions

* `columninfo`: Get basic information about a specific column in a table
* `connect`/`disconnect`: Set up and shut down connections to database
* `errcode`: Get the native error code for the database
* `errstring`: Get the native error string for the database
* `execute`: Execute a SQL statement with optional per-call variable bindings
* `executed`: How many times has this statement been executed
* `fetchall`: Fetch all rows as an array of arrays
* `fetchdf`: Fetch all rows as a DataFrame
* `fetchrow`: Fetch a row as an Array{Any}
* `finish`: Finalize a SQL statement's execution
* `lastinsertid`: What was the row ID of the last row inserted into a table
* `prepare`: Ask the database to prepare, but not execute, a SQL statement
* `run`: Run a non-`SELECT` SQL statement
* `sqlescape`: Escape a SQL statement to prevent injections
* `sql2jltype`: Convert a SQL type into a Julia `DataType`
* `select`: Combine a call to `prepare`, `execute`, `fetchdf` and `finish` to produce a DataFrame based on a `SELECT` SQL statement
* `tableinfo`: Get metadata about a table

# Extended Usage Example

In this example, we demonstrate how the DBI interface is used with
SQLite3. Changing the database type in the call to `connect` should be
sufficient to make this example work with other databases.

    using DBI
    using SQLite

    db = connect(SQLite3, "users.sqlite3")

    stmt = prepare(db, "CREATE TABLE users (id INT NOT NULL, name VARCHAR(255))")
    execute(stmt)
    finish(stmt)

    stmt = prepare(db, "INSERT INTO users VALUES (1, 'Jeff Bezanson')")
    execute(stmt)
    finish(stmt)

    stmt = prepare(db, "INSERT INTO users VALUES (2, 'Viral Shah')")
    execute(stmt)
    finish(stmt)

    run(db, "INSERT INTO users VALUES (3, 'Stefan Karpinski')")

    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    row = fetchrow(stmt)
    row = fetchrow(stmt)
    row = fetchrow(stmt)
    row = fetchrow(stmt)
    finish(stmt)

    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    rows = fetchall(stmt)
    finish(stmt)

    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    rows = fetchdf(stmt)
    finish(stmt)

    df = select(db, "SELECT * FROM users")

    tabledata = tableinfo(db, "users")

    columndata = columninfo(db, "users", "id")

    stmt = prepare(db, "DROP TABLE users")
    execute(stmt)
    finish(stmt)

    disconnect(db)

# Type Reference

**`DatabaseSystem`**

An abstract type that represents a specific database type like `SQLite3` or `MySQL`.

---

**`DatabaseHandle`**

An abstract type that represents a connection to a database. Every statement must contain the following field(s):

* `status`: The most recent recent code reported by the database

---

**`StatementHandle`**

An abstract type that represents a prepared SQL statement ready for execution. Every statement must contain the following field(s):

* `db`: The database against which the statement was prepared
* `executed`: The number of times the statement has been executed

---

**`DatabaseTable`**

Represents metadata about a table.

* `name::UTF8String`: The name of the table
* `columns::Vector{DatabaseColumn}`: Metadata about each column of the table as a `DatabaseColumn` object

---

**`DatabaseColumn`**

Represents metadata about one column in a table.

* `name::UTF8String`: The column's name
* `datatype::DataType`: The column's Julia type
* `length::Int`: The column's length if it is a `VARCHAR` column
* `collation::UTF8String`: The column's collation rule
* `nullable::Bool`: Can the column contain `NULL`?
* `primarykey::Bool`: Is the column part of a primary key?
* `autoincrement::Bool`: Is the column set to autoincrement on insertion?

# Function Reference

**`columninfo(db::DatabaseHandle, table::String, column::String) -> DatabaseColumn`**

Get basic information about a specific column in a table in the form of a `DatabaseColumn` type.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    coldata = columninfo(db, "users", "id")

---

**`connect(::Type{DatabaseSystem}, args::Any...) -> DatabaseHandle`**

Set up a connection to a database by specifying the type of database and
any information required to make the connection. Different databases expect
substantially different types of information.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")

---

**`connect(f::Function, ::Type{DatabaseSystem}, args::Any...)`**

Set up a connection to a database, apply the function f to the connection, and disconnect on return or error.

**Usage example**

    using DBI
    using SQLite

    connect(SQLite3, "db.sqlite3") do conn
        println("Connected.")
        error("Something went wrong.")
    end

    println("Disconnected.")

---

**`disconnect(db::DatabaseHandle) -> Nothing`**

Shut down a connection to a database safely.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    disconnect(db)

---

**`errcode(db::DatabaseHandle) -> Cint`**

Get the native error code for the database.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    errcode(db)
    disconnect(db)

---

**`errstring(db::DatabaseHandle) -> UTF8String` -**

Get the native error string for the database.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    errstring(db)
    disconnect(db)

---

**`execute(stmt::StatementHandle) -> Nothing`**

Execute a SQL statement with optional per-call variable bindings, which were indicated using `?` in the SQL statement at the time of a call to `prepare()`.

*Note that every call to `execute(stmt)` updates the status of `stmt.db.status`, which can be checked for information about the success or failure of the most recent attempt at execution of the statement.*

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)

---

**`executed(stmt::StatementHandle) -> Int`

How many times has this statement been executed?

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    executed(stmt)
    execute(stmt)
    executed(stmt)

---

**`fetchall(stmt::StatementHandle) -> Vector{Vector{Any}}`**

Fetch all rows returned by a statement as an `Vector{Vector{Any}}`.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    rows = fetchall(stmt)

---

**`fetchdf(stmt::StatementHandle) -> DataFrame`**

Fetch all rows returned by a statement as a `DataFrame`.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    df = fetchdf(stmt)

---

**`fetchrow(stmt::StatementHandle) -> Vector{Any}`**

Fetch the current row returned by execution of a statement as an `Vector{Any}`.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    row = fetchrow(stmt)

---

**`finish(stmt::StatementHandle) -> Nothing`**

Finalize a SQL statement's execution.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")
    execute(stmt)
    row = fetchrow(stmt)
    finish(stmt)

---

**`lastinsertid(db::DatabaseHandle, table::String) -> Int`

Determine the row ID of the last row inserted into `table`.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "INSERT INTO users (name) VALUES ('foo')")
    execute(stmt)
    lastinsertid(db, "users")

---

**`prepare(db::DatabaseHandle, sql::String) -> StatementHandle`**

Ask the database to prepare, but not execute, a SQL statement.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    stmt = prepare(db, "SELECT * FROM users")

---

**`run(db::DatabaseHandle, sql::String) -> Nothing`**

Combine a call to `prepare`, `execute` and `finish` to run a non-`SELECT` SQL statement.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    run(db, "DROP TABLE users")

---

**`sqlescape(sql::String) -> UTF8String`**

Escape a SQL statement to prevent SQL injections.

**This function is not yet implemented.**

**Usage example**

    using DBI
    safesql = sqlescape("SELECT * FROM users WHERE id = `a`)

---

**`sql2jltype(typestring::String) -> DataType`**

Convert a SQL type into a Julia `DataType`.

**Usage example**

    using DBI
    T = sql2jltype("VARCHAR(255)")
    @assert T == UTF8String

---

**`select(db::DatabaseHandle, sql::String) -> DataFrame`**

Combine a call to `prepare`, `execute`, `fetchdf` and `finish` to produce a DataFrame based on a `SELECT` SQL statement

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    df = select(db, "SELECT * FROM users")

---

**`tableinfo(db::DatabaseTable, table::String) -> DatabaseTable`**

Get metadata about a specific table in a database in the form of a `DatabaseTable` type.

**Usage example**

    using DBI
    using SQLite

    db = connect(SQLite3, "db.sqlite3")
    tabledata = tableinfo(db, "users")

# Coming Soon

* Implement `sqlescape()`
* Cross-database error and status reporting
* More convenience wrappers that combine primitives into simpler abstractions like `run` and `select
