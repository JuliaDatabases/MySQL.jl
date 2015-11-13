using Faker

function create_queries(number_of_datasets)
    println("*** Generating random data for $number_of_datasets tuples")
    tint = [rand(-128:127) for i=1 : number_of_datasets]                                     # TINYINT
    sint = [rand(-32768:32767) for i=1 : number_of_datasets]                                 # SMALLINT
    mint = [rand(-8388608:8388607) for i=1 : number_of_datasets]                             # MEDIUMINT
    rint = [rand(-2147483648:2147483647) for i=1 : number_of_datasets]                       # INT and INTEGER
    bint = [rand(-9223372036854775808:9223372036854775807) for i=1 : number_of_datasets]     # BIGINT
    rfloat = [rand(Float16) for i=1 : number_of_datasets]                                    # FLOAT
    dfloat = [rand(Float32) for i=1 : number_of_datasets]                                    # DOUBLE
    dpfloat = [rand(Float64) for i=1 : number_of_datasets]                                   # DOULBE PRECISION, REAL, DECIMAL
    datetime = [Faker.date_time_ad() for i=1 : number_of_datasets]                           # DATETIME, TIMESTAMP, DATE
    chara = [randstring(1) for i=1 : number_of_datasets]                                     # CHAR
    varcha = [randstring(rand(1:4000)) for i=1 : number_of_datasets]                         # VARCHAR , VARCHAR2, TINYTEXT, TEXT
    jobtype = ["HR", "Management", "Accounts"]                                               # ENUM
    enume = [jobtype[rand(1:3)] for i=1 : number_of_datasets]

    println("*** Done generating random data")
    return varcha, rfloat, datetime, tint, enume, mint, rint, bint, dfloat, dpfloat, chara, sint
end

function insert_queries(number_of_datasets)
    println("*** Generating insert queries for $number_of_datasets tuples")
    insert_query = Array(AbstractString, number_of_datasets)
    varcha, rfloat, datetime, tint, enume, mint, rint, bint, dfloat, dpfloat, chara, sint = create_queries(number_of_datasets)
    for i = 1:number_of_datasets
        insert_query[i] = "INSERT INTO Employee (Name, Salary, LastLogin, OfficeNo, JobType,h, n, z, z1, z2, cha, empno) VALUES ('$(varcha[i])', $(rfloat[i]), '$(datetime[i])', $(tint[i]), '$(enume[i])', $(mint[i]), $(rint[i]), $(bint[i]), $(dfloat[i]), $(dpfloat[i]), '$(chara[i])', $(sint[i]));"
    end
    println("*** Done generating insert queries")
    return insert_query
end


function update_queries(number_of_datasets)
    println("*** Generating update queries for $number_of_datasets tuples")
    number_of_datasets = number_of_datasets
    update_query = Array(AbstractString, number_of_datasets)
    varcha, rfloat, datetime, tint, enume, mint, rint, bint, dfloat, dpfloat, chara, sint = create_queries(number_of_datasets)
    for i = 1:number_of_datasets
        update_query[i] = "UPDATE Employee SET Name='$(varcha[i])', Salary=$(rfloat[i]), LastLogin='$(datetime[i])', OfficeNo=$(tint[i]), JobType='$(enume[i])', h=$(mint[i]), n=$(rint[i]), z=$(bint[i]), z1=$(dfloat[i]), z2=$(dpfloat[i]), cha='$(chara[i])', empno=$(sint[i]) where ID = $i;"
    end
    println("*** Done generating update queries")
    return update_query
end
