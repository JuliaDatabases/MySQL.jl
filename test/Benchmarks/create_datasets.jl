using Faker
using JLD, HDF5
number_of_datasets = 100000

function create_queries(number_of_datasets=100001)
  # TINYINT
  tint = [rand(-128:127) for i=1 : number_of_datasets]
  # SMALLINT
  sint = [rand(-32768:32767) for i=1 : number_of_datasets]
  # MEDIUMINT
  mint = [rand(-8388608:8388607) for i=1 : number_of_datasets]
  # INT and INTEGER
  rint = [rand(-2147483648:2147483647) for i=1 : number_of_datasets]
  # BIGINT
  bint = [rand(-9223372036854775808:9223372036854775807) for i=1 : number_of_datasets]
  # FLOAT
  rfloat = [rand(Float16) for i=1 : number_of_datasets]
  # DOUBLE
  dfloat = [rand(Float32) for i=1 : number_of_datasets]
  # DOULBE PRECISION, REAL, DECIMAL
  dpfloat = [rand(Float64) for i=1 : number_of_datasets]
  #DATETIME, TIMESTAMP, DATE
  datetime = [Faker.date_time_ad() for i=1 : number_of_datasets]
  #CHAR
  chara = [randstring(1) for i=1 : number_of_datasets]
  #VARCHAR , VARCHAR2, TINYTEXT, TEXT
  varcha = [randstring(rand(1:4000)) for i=1 : number_of_datasets]
  #ENUM
  JobType = ["HR", "Management", "Accounts"]
  enume = [JobType[rand(1:3)] for i=1 : number_of_datasets]
  return varcha, rfloat, datetime, tint, enume, mint, rint, bint, dfloat, dpfloat, chara, sint
end

function insert_queries(number_of_datasets=100001)
    Insert_Query = Array(String, (number_of_datasets))
    create_table = "CREATE TABLE Employee(ID INT NOT NULL AUTO_INCREMENT, Name VARCHAR(4000), Salary FLOAT, LastLogin DATETIME, OfficeNo TINYINT, JobType ENUM('HR', 'Management', 'Accounts'), h MEDIUMINT, n INTEGER, z BIGINT, z1 DOUBLE, z2 DOUBLE PRECISION, cha CHAR, empno SMALLINT, PRIMARY KEY (ID));"
    Insert_Query[1] = create_table
    varcha, rfloat, datetime, tint, enume, mint, rint, bint, dfloat, dpfloat, chara, sint = create_queries(number_of_datasets)
    for i=2 :(number_of_datasets)
      Insert_Query[i] = "INSERT INTO Employee (Name, Salary, LastLogin, OfficeNo, JobType,h, n, z, z1, z2, cha, empno) VALUES ('$(varcha[i])', $(rfloat[i]), '$(datetime[i])', $(tint[i]), '$(enume[i])', $(mint[i]), $(rint[i]), $(bint[i]), $(dfloat[i]), $(dpfloat[i]), '$(chara[i])', $(sint[i]));"
    end
    return Insert_Query
end


function update_queries(number_of_datasets=100001)
    number_of_datasets = number_of_datasets -1
    Update_Query = Array(String, (number_of_datasets))
    varcha, rfloat, datetime, tint, enume, mint, rint, bint, dfloat, dpfloat, chara, sint = create_queries(number_of_datasets)
    for i=1 : (number_of_datasets)
      Update_Query[i] = "UPDATE Employee SET Name='$(varcha[i])', Salary=$(rfloat[i]), LastLogin='$(datetime[i])', OfficeNo=$(tint[i]), JobType='$(enume[i])', h=$(mint[i]), n=$(rint[i]), z=$(bint[i]), z1=$(dfloat[i]), z2=$(dpfloat[i]), cha='$(chara[i])', empno=$(sint[i]) where ID = $i;"
    end
    return Update_Query
end
