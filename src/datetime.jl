# Constructors for the julia Date, Time and DateTime types.

using Requires

import Base.==

function MySQLTime(timestr)
    h, m, s = split(timestr, ':')
    MySQLTime(parse(Cint, h), parse(Cint, m), parse(Cint, s))
end

function MySQLTime(mtime::MYSQL_TIME)
    MySQLTime(mtime.hour, mtime.minute, mtime.second)
end

function MySQLDate(datestr)
    y, m, d = split(datestr, '-')
    MySQLDate(parse(Cint, y), parse(Cint, m), parse(Cint, d))
end

function MySQLDate(mtime::MYSQL_TIME)
    MySQLDate(mtime.year, mtime.month, mtime.day)
end

function MySQLDateTime(dtimestr)
    d, t = split(dtimestr, ' ')
    MySQLDateTime(MySQLDate(d), MySQLTime(t))
end

function MySQLDateTime(mtime::MYSQL_TIME)
    MySQLDateTime(MySQLDate(mtime), MySQLTime(mtime))
end

function Base.convert(::Type{AbstractString}, time::MySQLTime)
    "$(time.hour):$(time.minute):$(time.second)"
end

function Base.convert(::Type{AbstractString}, date::MySQLDate)
    "$(date.year)-$(date.month)-$(date.day)"
end

function Base.convert(::Type{AbstractString}, dtime::MySQLDateTime)
    convert(AbstractString, dtime.date) * " " * convert(AbstractString, dtime.time)
end

function Base.show(io::IO, date::MySQLDate)
    print(io, convert(AbstractString, date))
end

function Base.show(io::IO, time::MySQLTime)
    print(io, convert(AbstractString, time))
end

function Base.show(io::IO, dtime::MySQLDateTime)
    print(io, convert(AbstractString, dtime))
end

function Base.convert(::Type{MYSQL_TIME}, time::MySQLTime)
    MYSQL_TIME(0, 0, 0, time.hour, time.minute, time.second, 0, 0, 0)
end

function Base.convert(::Type{MYSQL_TIME}, date::MySQLDate)
    MYSQL_TIME(date.year, date.month, date.day, 0, 0, 0, 0, 0, 0)
end

function Base.convert(::Type{MYSQL_TIME}, dtime::MySQLDateTime)
    MYSQL_TIME(dtime.date.year, dtime.date.month, dtime.date.day,
               dtime.time.hour, dtime.time.minute, dtime.time.second, 0, 0, 0)
end

function ==(a::MySQLDate, b::MySQLDate)
    a.year == b.year && a.month == b.month && a.day == b.day
end

function ==(a::MySQLTime, b::MySQLTime)
    a.hour == b.hour && a.minute == b.minute && a.second == b.second
end

function ==(a::MySQLDateTime, b::MySQLDateTime)
    a.date == b.date && a.time == b.time
end

@require Dates begin
using Dates
Base.convert(::Type{Date}, date::MySQLDate) = Date(date.year, date.month, date.day)
Base.convert(::Type{DateTime}, dtime::MySQLDateTime) =
    DateTime(dtime.date.year, dtime.date.month, dtime.date.day,
             dtime.time.hour, dtime.time.minute, dtime.time.second)
end
