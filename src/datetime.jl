# Constructors for the julia Date, Time and DateTime types.

import Base.==

const MYSQL_DATE_FORMAT = Dates.DateFormat("yyyy-mm-dd")
const MYSQL_DATETIME_FORMAT = Dates.DateFormat("yyyy-mm-dd HH:MM:SS")

function Base.convert(::Type{Date}, datestr::String)
    Date(datestr, MYSQL_DATE_FORMAT)
end

function Base.convert(::Type{DateTime}, dtimestr::String)
    if !contains(dtimestr, " ")
        dtimestr = "1970-01-01 " * dtimestr
    end
    DateTime(dtimestr, MYSQL_DATETIME_FORMAT)
end

function Base.convert(::Type{DateTime}, mtime::MYSQL_TIME)
    if mtime.year == 0 || mtime.month == 0 || mtime.day == 0
        DateTime(1970, 1, 1,
                 mtime.hour, mtime.minute, mtime.second)
    else
        DateTime(mtime.year, mtime.month, mtime.day,
                 mtime.hour, mtime.minute, mtime.second)
    end
end

function Base.convert(::Type{Date}, mtime::MYSQL_TIME)
    Date(mtime.year, mtime.month, mtime.day)
end

function Base.convert(::Type{MYSQL_TIME}, date::Date)
    MYSQL_TIME(Dates.year(date), Dates.month(date), Dates.day(date), 0, 0, 0, 0, 0, 0)
end

function Base.convert(::Type{MYSQL_TIME}, dtime::DateTime)
    if Dates.year(dtime) == 1970 && Dates.month(dtime) == 1 && Dates.day(dtime) == 1
        MYSQL_TIME(0, 0, 0,
                   Dates.hour(dtime), Dates.minute(dtime), Dates.second(dtime), 0, 0, 0)
    else
        MYSQL_TIME(Dates.year(dtime), Dates.month(dtime), Dates.day(dtime),
                   Dates.hour(dtime), Dates.minute(dtime), Dates.second(dtime), 0, 0, 0)
    end
end
