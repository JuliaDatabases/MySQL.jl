function MySQLRowIterator(result::MySQLResult)
    meta = mysql_metadata(result)
    nrows = mysql_num_rows(result)
    return MySQLRowIterator(result, meta.jtypes, meta.is_nullables, nrows)
end

function MySQLRowIterator(con::MySQLHandle, command)
    mysql_query(con, command)
    result = mysql_store_result(con)
    return MySQLRowIterator(result)
end

function MySQLRowIterator(hndl::MySQLHandle, typs, values)
    bindarr = mysql_bind_array(typs, values)
    mysql_stmt_bind_param(hndl, bindarr)
    return MySQLRowIterator(hndl)
end

MySQLRowIterator(hndl::MySQLHandle) = MySQLStatementIterator(hndl)

Base.start(itr::MySQLRowIterator) = true

function Base.next(itr::MySQLRowIterator, state)
    row = mysql_fetch_row(itr.result)
    row == C_NULL && throw(MySQLInterfaceError("Unable to fetch row, you must re-execute the query."))
    itr.rowsleft -= 1
    return (mysql_get_row_as_tuple(row, itr.jtypes, itr.is_nullables), state)
end

Base.done(itr::MySQLRowIterator, state) = itr.rowsleft == 0

function MySQLStatementIterator(hndl::MySQLHandle)
    meta = mysql_metadata(hndl)
    bindres = mysql_bind_array(meta)
    mysql_stmt_bind_result(hndl, bindres)
    mysql_stmt_execute(hndl)
    return MySQLStatementIterator(hndl, meta.jtypes, meta.is_nullables, bindres)
end

Base.start(itr::MySQLStatementIterator) = true

Base.next(itr::MySQLStatementIterator, state) =
    (mysql_get_row_as_tuple(itr.binding, itr.jtypes, itr.is_nullables), state)

Base.done(itr::MySQLStatementIterator, state) = mysql_stmt_fetch(itr.hndl) == MYSQL_NO_DATA
