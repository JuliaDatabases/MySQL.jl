# Constructors for the julia Date, Time and DateTime types.

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

function Base.convert(::Type{String}, time::MySQLTime)
    "$(time.hour):$(time.minute):$(time.second)"
end

function Base.convert(::Type{String}, date::MySQLDate)
    "$(date.year)-$(date.month)-$(date.day)"
end

function Base.convert(::Type{String}, dtime::MySQLDateTime)
    convert(String, dtime.date) * " " * convert(String, dtime.time)
end

function Base.show(io::IO, date::MySQLDate)
    print(io, convert(String, date))
end

function Base.show(io::IO, time::MySQLTime)
    print(io, convert(String, time))
end

function Base.show(io::IO, dtime::MySQLDateTime)
    print(io, convert(String, dtime))
end
