# Constructors for the julia Date, Time and DateTime types.

if VERSION < v"0.4-"
    using Dates
else
    using Base.Dates
end

import Base.==

function MySQLTime(timestr)
    h, m, s = split(timestr, ':')
    MySQLTime(parse(Cint, h), parse(Cint, m), parse(Cint, s))
end

function MySQLTime(mtime::MYSQL_TIME)
    MySQLTime(mtime.hour, mtime.minute, mtime.second)
end

function Base.convert(::Type{Date}, datestr::AbstractString)
    y, m, d = split(datestr, '-')
    Date(parse(Cint, y), parse(Cint, m), parse(Cint, d))
end

function Base.convert(::Type{Date}, mtime::MYSQL_TIME)
    Date(mtime.year, mtime.month, mtime.day)
end

function Base.convert(::Type{DateTime}, dtimestr::AbstractString)
    d, t = split(dtimestr, ' ')
    date = convert(Date, d)
    time = MySQLTime(t)
    DateTime(Dates.year(date), Dates.month(date), Dates.day(date),
             time.hour, time.minute, time.second)
end

function Base.convert(::Type{DateTime}, mtime::MYSQL_TIME)
    DateTime(mtime.year, mtime.month, mtime.day,
             mtime.hour, mtime.minute, mtime.second)
end

function Base.convert(::Type{AbstractString}, time::MySQLTime)
    "$(time.hour):$(time.minute):$(time.second)"
end

function Base.show(io::IO, time::MySQLTime)
    print(io, convert(AbstractString, time))
end

function Base.convert(::Type{MYSQL_TIME}, time::MySQLTime)
    MYSQL_TIME(0, 0, 0, time.hour, time.minute, time.second, 0, 0, 0)
end

function Base.convert(::Type{MYSQL_TIME}, date::Date)
    MYSQL_TIME(Dates.year(date), Dates.month(date), Dates.day(date), 0, 0, 0, 0, 0, 0)
end

function Base.convert(::Type{MYSQL_TIME}, dtime::DateTime)
    MYSQL_TIME(Dates.year(dtime), Dates.month(dtime), Dates.day(dtime),
               Dates.hour(dtime), Dates.minute(dtime), Dates.second(dtime), 0, 0, 0)
end

function ==(a::MySQLTime, b::MySQLTime)
    a.hour == b.hour && a.minute == b.minute && a.second == b.second
end
