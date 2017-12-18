module test_basic

include("test_common.jl")

const ArrayResults = Array{Any}[
    Any[1, "John", 10000.5f0, convert(Date, "2015-08-03"),
     convert(DateTime, "2015-09-05 12:31:30"),
     convert(DateTime, "1970-01-01 12:00:00"),
     Int8(1), "HR", 0x01, Int16(1301)],

    Any[2, "Tom", 20000.25f0, convert(Date, "2015-08-04"),
     convert(DateTime, "2015-10-12 13:12:14"),
     convert(DateTime, "1970-01-01 13:00:00"),
     Int8(12), "HR", 0x01, Int16(1422)],

    Any[3, "Jim", 25000.0f0, convert(Date, "2015-06-02"),
     convert(DateTime, "2015-09-05 10:05:10"),
     convert(DateTime, "1970-01-01 12:30:00"),
     Int8(45), "Management", missing, Int16(1567)],

    Any[4, "Tim", 25000.0f0, convert(Date, "2015-07-25"),
     convert(DateTime, "2015-10-10 12:12:25"),
     convert(DateTime, "1970-01-01 12:30:00"),
     Int8(56), "Accounts", 0x01, Int16(3200)],

    Any[5, missing, missing, missing,
     missing, missing,
     missing, missing, missing, missing]]

const DataFrameResults = DataFrame(
    ID=[1, 2, 3, 4, 5],
    Name=["John", "Tom", "Jim", "Tim", missing],
    Salary=[10000.5, 20000.3, 25000.0, 25000.0, missing],
    JoinDate=[convert(Date, "2015-8-3"), convert(Date, "2015-8-4"),
              convert(Date, "2015-6-2"), convert(Date, "2015-7-25"), missing],
    LastLogin=[convert(DateTime, "2015-9-5 12:31:30"),
               convert(DateTime, "2015-10-12 13:12:14"),
               convert(DateTime, "2015-9-5 10:5:10"),
               convert(DateTime, "2015-10-10 12:12:25"), missing],
    LunchTime=[convert(DateTime, "12:0:0"), convert(DateTime, "13:0:0"),
               convert(DateTime, "12:30:0"), convert(DateTime, "12:30:0"), missing],
    OfficeNo=[1, 12, 45, 56, missing],
    JobType=["HR", "HR", "Management", "Accounts", missing],
    Senior=[0x01, 0x01, missing, 0x01, missing],
    empno=[1301, 1422, 1567, 3200, missing])

function run_query_helper(command, msg)
    response = mysql_query(hndl, command)

    if (response == 0)
        println("SUCCESS: " * msg)
        return true
    else
        println("FAILED: " * msg)
        return false
    end
end

function show_results()
    command = """SELECT * FROM Employee;"""
    dframe = mysql_execute(hndl, command)[1]
    println("\n *** Results as Dataframe: \n", dframe)
    println("\n *** Expected Result: \n", DataFrameResults)
    @test dfisequal(dframe, DataFrameResults)

    println("\n *** Results using Iterator: \n")
    i = 1
    for row in MySQLRowIterator(hndl, command)
        println(row)
        @test compare_rows(row, ArrayResults[i])
        i += 1
    end

    println("\n *** Results as tuples: \n")
    tupres = mysql_execute(hndl, command; opformat=MYSQL_TUPLES)[1]
    println(tupres)
    for i in length(tupres)
        @test compare_rows(tupres[i], ArrayResults[i])
    end

    validate_metadata()

    # Test quoting works as expected
    @test mysql_escape(hndl, "quoting 'test'") == "quoting \\'test\\'"
end

function validate_metadata()
    mysql_query(hndl, "SELECT * FROM Employee;")
    result = mysql_store_result(hndl)
    meta = mysql_metadata(result)
    @test meta.names[1] == "ID"
    @test meta.lens[1] == 11
    @test meta.mtypes[1] == MYSQL_TYPE_LONG
    @test meta.jtypes[1] == Union{Missings.Missing, Int32}
    @test meta.is_nullables[1] == false

    @test meta.names[2] == "Name"
    # @test meta.lens[2] == 255
    @test meta.mtypes[2] == MYSQL_TYPE_VAR_STRING
    @test meta.jtypes[2] == Union{Missings.Missing, String}
    @test meta.is_nullables[2] == true
end

println("\n*** Running Basic Test ***\n")
run_test()

end
