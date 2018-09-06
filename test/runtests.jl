using Test, MySQL, Tables, Dates

if haskey(ENV, "APPVEYOR_BUILD_NUMBER")
    pwd = "Password12!"
else
    pwd = ""
end

const conn = MySQL.connect("127.0.0.1", "root", pwd; port=3306)

MySQL.execute!(conn, "DROP DATABASE if exists mysqltest")
MySQL.execute!(conn, "CREATE DATABASE mysqltest")
MySQL.execute!(conn, "use mysqltest")
MySQL.execute!(conn, """CREATE TABLE Employee
                 (
                     ID INT NOT NULL AUTO_INCREMENT,
                     Name VARCHAR(255),
                     Salary FLOAT(7,2),
                     JoinDate DATE,
                     LastLogin DATETIME,
                     LunchTime TIME,
                     OfficeNo TINYINT,
                     JobType ENUM('HR', 'Management', 'Accounts'),
                     Senior BIT(1),
                     empno SMALLINT,
                     PRIMARY KEY (ID)
                 );""")

MySQL.execute!(conn, """INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime, OfficeNo, JobType, Senior, empno)
                 VALUES
                 ('John', 10000.50, '2015-8-3', '2015-9-5 12:31:30', '12:00:00', 1, 'HR', b'1', 1301),
                 ('Tom', 20000.25, '2015-8-4', '2015-10-12 13:12:14', '13:00:00', 12, 'HR', b'1', 1422),
                 ('Jim', 30000.00, '2015-6-2', '2015-9-5 10:05:10', '12:30:00', 45, 'Management', b'0', 1567),
                 ('Tim', 15000.50, '2015-7-25', '2015-10-10 12:12:25', '12:30:00', 56, 'Accounts', b'1', 3200);
              """)

# id = MySQL.insertid(conn)
# println("Last insert id was $id")

res = MySQL.query(conn, "select * from Employee")

@test length(res) == 10
@test length(res[1]) == 4
@test res.ID == [1,2,3,4]

expected = (
  ID        = Int32[1, 2, 3, 4],
  Name      = Union{Missing, String}["John", "Tom", "Jim", "Tim"],
  Salary    = Union{Missing, Float32}[10000.5, 20000.25, 30000.0, 15000.5],
  JoinDate  = Union{Missing, Dates.Date}[Date("2015-08-03"), Date("2015-08-04"), Date("2015-06-02"), Date("2015-07-25")],
  LastLogin = Union{Missing, Dates.DateTime}[DateTime("2015-09-05T12:31:30"), DateTime("2015-10-12T13:12:14"), DateTime("2015-09-05T10:05:10"), DateTime("2015-10-10T12:12:25")],
  LunchTime = Union{Missing, Dates.Time}[Dates.Time(12,00,00), Dates.Time(13,00,00), Dates.Time(12,30,00), Dates.Time(12,30,00)],
  OfficeNo  = Union{Missing, Int8}[1, 12, 45, 56],
  JobType   = Union{Missing, String}["HR", "HR", "Management", "Accounts"],
  Senior    = Union{Missing, MySQL.API.Bit}[MySQL.API.Bit(1), MySQL.API.Bit(1), MySQL.API.Bit(0), MySQL.API.Bit(1)],
  empno     = Union{Missing, Int16}[1301, 1422, 1567, 3200],
)

@test res == expected

# insert null row
MySQL.execute!(conn, "INSERT INTO Employee () VALUES ();")

res = MySQL.query(conn, "select * from Employee")

foreach(x->push!(x[2], x[1] == 1 ? Int32(5) : missing), enumerate(expected))
@test isequal(res, expected)

q = MySQL.Query(conn, "select * from Employee")
for row in q
    println(row)
end

@test MySQL.escape(conn, "quoting 'test'") == "quoting \\'test\\'"

stmt = MySQL.Stmt(conn, "UPDATE Employee SET Salary = ? WHERE ID > ?;")
affrows = MySQL.execute!(stmt, [25000, 2])

res = MySQL.query(conn, "select Salary from Employee")
@test all(res[1][3:end] .== 25000)

affrows = MySQL.execute!(stmt, [missing, 2])

res = MySQL.query(conn, "select Salary from Employee")
@test all(res[1][3:end] .=== missing)

stmt = MySQL.Stmt(conn, "INSERT INTO Employee (Name, Salary, JoinDate, LastLogin, LunchTime, OfficeNo, empno) VALUES (?, ?, ?, ?, ?, ?, ?);")

values = [(Name="John", Salary=10000.50, JoinDate=Date("2015-8-3"), LastLogin=DateTime("2015-9-5T12:31:30"), LunchTime=Dates.Time(12,00,00), OfficeNo=1, empno=1301),
          (Name="Tom",  Salary=20000.25, JoinDate=Date("2015-8-4"), LastLogin=DateTime("2015-10-12T13:12:14"), LunchTime=Dates.Time(13,00,00), OfficeNo=12, empno=1422),
          (Name="Jim",  Salary=30000.00, JoinDate=Date("2015-6-2"), LastLogin=DateTime("2015-9-5T10:05:10"), LunchTime=Dates.Time(12,30,00), OfficeNo=45, empno=1567),
          (Name="Tim",  Salary=15000.50, JoinDate=Date("2015-7-25"), LastLogin=DateTime("2015-10-10T12:12:25"), LunchTime=Dates.Time(12,30,00), OfficeNo=56, empno=3200)]

MySQL.execute!(values, stmt)

res = MySQL.query(conn, "select * from Employee")
@test length(res) == 10
@test length(res[1]) == 9

# test multi-statement execution
MySQL.execute!(conn, """DROP DATABASE if exists mysqltest2;
    CREATE DATABASE mysqltest2;
    USE mysqltest2;
    CREATE TABLE test (a varchar(20), b integer);
    INSERT INTO test (a,b) value ("test",123);""")

res = MySQL.query(conn, """select * from test;""")

@test res.a[1] == "test"
@test res.b[1] == 123
