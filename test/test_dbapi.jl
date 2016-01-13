using MySQL
using Base.Test

println("\n*** Starting DBAPI test \n")
conn = connect(MySQLInterface, HOST, "root", ROOTPASS, "")
csr = cursor(conn)
try
    execute!(csr, "blah blah blah;")
catch e
    @test isa(e, MySQLInternalError)
end
execute!(csr, "DROP DATABASE IF EXISTS mydb;")
execute!(csr, "CREATE DATABASE mydb;")
execute!(csr, "CREATE TABLE mydb.mytable (id int not null auto_increment, name varchar(50) not null, age int, birthday date, primary key (id));")
execute!(csr, "INSERT INTO mydb.mytable (name, age, birthday) values ('John', 23, '1992-02-23'), ('Tom', 32, '1983-05-06'), ('Mary', 58, '1969-02-03');")
println("Table created, values inserted.")

execute!(csr, "SELECT * from mydb.mytable;")
res = collect(rows(csr))
@test length(res) == 3
@test length(res[1]) == 4
@test typeof(res[1]) == Tuple{Int32, ASCIIString, Nullable{Int32}, Nullable{Date}}
@test res[1][2] == "John"
@test res[2][3].value == 32
@test res[3][4].value == Date("1969-02-03")
println("SELECT result validated.")

close(csr)
close(conn)
try
    close(conn)
catch e
    @test isa(e, MySQLError)
end
try
    csr = cursor(conn)
catch e
    @test isa(e, MySQLError)
end
try
    execute!(csr, "SELECT * from mydb.mytable;")
catch e
    @test isa(e, MySQLError)
end

conn = connect(MySQLInterface, HOST, "root", ROOTPASS, "")
csr = cursor(conn)
execute!(csr, "DROP DATABASE mydb;")
close(csr)
close(conn)
println("\n*** End DBAPI test \n")
