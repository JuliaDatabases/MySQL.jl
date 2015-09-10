using MySQL

const HOST = "127.0.0.1"
const USER = "root"
const PASSWD = "root"
const DBNAME = "mysqltest"
db = MySQL.connect(HOST, USER, PASSWD, DBNAME)

sql = "select * from datetimetable limit 10"

println("SQL executed is :: $sql")    
const PREPARE = false
df = null

if( PREPARE != true )
    df = MySQL.execute_query(db, sql, 0)
else
    ## Test for prepare statements
    stmt_ptr = MySQL.stmt_init(db)
    df = MySQL.prepare_and_execute(stmt_ptr, sql)
    MySQL.stmt_close(stmt_ptr)
end

println(df)
MySQL.disconnect(db)
