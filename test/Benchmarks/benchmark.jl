using MySQL
using DataFrames
using JLD, HDF5
include("create_datasets.jl")
number_of_datasets = 10000
Multi_Query = 0

function mysql_benchmarks(queries,use_prepare=0, Multi_Query = 0,operation=" ")
  conn = mysql_connect("127.0.0.1", "root", "root", "mysqltest1")
  println("Time taken by MySQL wrapper for operation $operation on a dataset with 100000 rows and 12 coloumns (Composed of 12 different datatypes) is as follows")
  if use_prepare ==1
    stmt = mysql_stmt_init(conn)
    @time for i = 1:size(queries,1)
      mysql_stmt_prepare(stmt, queries[i])
      mysql_stmt_execute(stmt)
    end
    mysql_stmt_close(stmt)
  elseif Multi_Query ==1
      temp = join(queries)
      @time mysql_execute_query(conn, temp)
  else
    @time for i = 1:size(queries,1)
      mysql_execute_query(conn, queries[i])
    end
  end
  println("Time taken for retrieving all the Inserted or Updated records by MySQL wrapper is ")
  @time mysql_execute_query(conn, "select ID, Name, Salary, OfficeNo, JobType,h, n, z, z1, z2, cha, empno from Employee")
  mysql_disconnect(conn)
end

function delete_table()
    conn = mysql_connect("127.0.0.1", "root", "root", "mysqltest1")
    try
      mysql_execute_query(conn,"drop table Employee")
      mysql_disconnect(conn)
    catch
      mysql_disconnect(conn)
      return
    end
end
function run_all_benchmarks()
  delete_table()
  println("Benchmark without using Prepare functionality")
  mysql_benchmarks(insert_queries(number_of_datasets),0,0,"Insert")
  mysql_benchmarks(update_queries(number_of_datasets),0,0,"Update")
  println("Benchmark using Prepare functionality")
  delete_table()
  mysql_benchmarks(insert_queries(number_of_datasets),1,0,"Insert")
  mysql_benchmarks(update_queries(number_of_datasets),1,0,"Update")
  println("Benchmark using Multiquery functionality")
  delete_table()
  mysql_benchmarks(insert_queries(number_of_datasets),0,1,"Insert")
  mysql_benchmarks(update_queries(number_of_datasets),0,1,"Update")
end

number_of_datasets = number_of_datasets + 1
run_all_benchmarks()
