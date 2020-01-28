macro checkstmtsuccess(stmt, code)
    return esc(quote
        result = $code
        result != 0 && throw(StmtError($stmt))
        result
    end)
end

"""
Description
mysql_stmt_affected_rows() may be called immediately after executing a statement with mysql_stmt_execute(). It is like mysql_affected_rows() but for prepared statements. For a description of what the affected-rows value returned by this function means, See Section 28.6.6.1, “mysql_affected_rows()”.
"""
function affectedrows(stmt::MYSQL_STMT)
    return mysql_stmt_affected_rows(stmt.ptr)
end

"""
Description
Can be used to get the current value for a statement attribute.

The option argument is the option that you want to get; the arg should point to a variable that should contain the option value. If the option is an integer, arg should point to the value of the integer.

See Section 28.6.10.3, “mysql_stmt_attr_set()”, for a list of options and option types.
"""
function attrget(stmt::MYSQL_STMT, option::enum_stmt_attr_type)
    if option in BOOL_STMT_ATTR
        ref = Ref{Bool}()
    elseif option in CULONG_STMT_ATTR
        ref = Ref{Culong}()
    end
    return @checkstmtsuccess stmt mysql_stmt_attr_get(stmt.ptr, option, ref)
end

"""
Description
Can be used to affect behavior for a prepared statement. This function may be called multiple times to set several options.

The option argument is the option that you want to set. The arg argument is the value for the option. arg should point to a variable that is set to the desired attribute value. The variable type is as indicated in the following table.

The following table shows the possible option values.

Option	Argument Type	Function
STMT_ATTR_UPDATE_MAX_LENGTH	bool *	If set to 1, causes mysql_stmt_store_result() to update the metadata MYSQL_FIELD->max_length value.
STMT_ATTR_CURSOR_TYPE	unsigned long *	Type of cursor to open for statement when mysql_stmt_execute() is invoked. *arg can be CURSOR_TYPE_NO_CURSOR (the default) or CURSOR_TYPE_READ_ONLY.
STMT_ATTR_PREFETCH_ROWS	unsigned long *	Number of rows to fetch from server at a time when using a cursor. *arg can be in the range from 1 to the maximum value of unsigned long. The default is 1.
If you use the STMT_ATTR_CURSOR_TYPE option with CURSOR_TYPE_READ_ONLY, a cursor is opened for the statement when you invoke mysql_stmt_execute(). If there is already an open cursor from a previous mysql_stmt_execute() call, it closes the cursor before opening a new one. mysql_stmt_reset() also closes any open cursor before preparing the statement for re-execution. mysql_stmt_free_result() closes any open cursor.

If you open a cursor for a prepared statement, mysql_stmt_store_result() is unnecessary, because that function causes the result set to be buffered on the client side.
"""
function attrset(stmt::MYSQL_STMT, option::enum_stmt_attr_type, arg)
    if option in BOOL_STMT_ATTR
        ref = Ref{Bool}(arg)
    elseif option in CULONG_STMT_ATTR
        ref = Ref{Culong}(arg)
    end
    return @checkstmtsuccess stmt mysql_stmt_attr_get(stmt.ptr, option, ref)
end

"""
Description
mysql_stmt_bind_param() is used to bind input data for the parameter markers in the SQL statement that was passed to mysql_stmt_prepare(). It uses MYSQL_BIND structures to supply the data. bind is the address of an array of MYSQL_BIND structures. The client library expects the array to contain one element for each ? parameter marker that is present in the query.

Suppose that you prepare the following statement:

INSERT INTO mytbl VALUES(?,?,?)
When you bind the parameters, the array of MYSQL_BIND structures must contain three elements, and can be declared like this:

MYSQL_BIND bind[3];
Section 28.6.8, “C API Prepared Statement Data Structures”, describes the members of each MYSQL_BIND element and how they should be set to provide input values.
"""
function bindparam(stmt::MYSQL_STMT, bind::Vector{MYSQL_BIND})
    return @checkstmtsuccess stmt mysql_stmt_bind_param(stmt.ptr, convert(Ptr{Cvoid}, pointer(bind)))
end

"""
Description
mysql_stmt_bind_result() is used to associate (that is, bind) output columns in the result set to data buffers and length buffers. When mysql_stmt_fetch() is called to fetch data, the MySQL client/server protocol places the data for the bound columns into the specified buffers.

All columns must be bound to buffers prior to calling mysql_stmt_fetch(). bind is the address of an array of MYSQL_BIND structures. The client library expects the array to contain one element for each column of the result set. If you do not bind columns to MYSQL_BIND structures, mysql_stmt_fetch() simply ignores the data fetch. The buffers should be large enough to hold the data values, because the protocol does not return data values in chunks.

A column can be bound or rebound at any time, even after a result set has been partially retrieved. The new binding takes effect the next time mysql_stmt_fetch() is called. Suppose that an application binds the columns in a result set and calls mysql_stmt_fetch(). The client/server protocol returns data in the bound buffers. Then suppose that the application binds the columns to a different set of buffers. The protocol places data into the newly bound buffers when the next call to mysql_stmt_fetch() occurs.

To bind a column, an application calls mysql_stmt_bind_result() and passes the type, address, and length of the output buffer into which the value should be stored. Section 28.6.8, “C API Prepared Statement Data Structures”, describes the members of each MYSQL_BIND element and how they should be set to receive output values.
"""
function bindresult(stmt::MYSQL_STMT, bind::Vector{MYSQL_BIND})
    return @checkstmtsuccess stmt mysql_stmt_bind_result(stmt.ptr, convert(Ptr{Cvoid}, pointer(bind)))
end

"""
Description
Closes the prepared statement. mysql_stmt_close() also deallocates the statement handler pointed to by stmt, which at that point becomes invalid and should no longer be used. For a failed mysql_stmt_close() call, do not call mysql_stmt_error(), or mysql_stmt_errno(), or mysql_stmt_sqlstate() to obtain error information because mysql_stmt_close() makes the statement handler invalid. Call mysql_error(), mysql_errno(), or mysql_sqlstate() instead.

If the current statement has pending or unread results, this function cancels them so that the next query can be executed.
"""
function close(stmt::MYSQL_STMT)
    return @checkstmtsuccess stmt mysql_stmt_close(stmt.ptr)
end

"""
Description
Seeks to an arbitrary row in a statement result set. The offset value is a row number and should be in the range from 0 to mysql_stmt_num_rows(stmt)-1.

This function requires that the statement result set structure contains the entire result of the last executed query, so mysql_stmt_data_seek() may be used only in conjunction with mysql_stmt_store_result().
"""
function dataseek(stmt::MYSQL_STMT, offset::Integer)
    return mysql_stmt_data_seek(stmt.ptr, offset)
end

"""
Description
mysql_stmt_execute() executes the prepared query associated with the statement handler. The currently bound parameter marker values are sent to server during this call, and the server replaces the markers with this newly supplied data.

Statement processing following mysql_stmt_execute() depends on the type of statement:

For an UPDATE, DELETE, or INSERT, the number of changed, deleted, or inserted rows can be found by calling mysql_stmt_affected_rows().

For a statement such as SELECT that generates a result set, you must call mysql_stmt_fetch() to fetch the data prior to calling any other functions that result in query processing. For more information on how to fetch the results, refer to Section 28.6.10.11, “mysql_stmt_fetch()”.

Do not following invocation of mysql_stmt_execute() with a call to mysql_store_result() or mysql_use_result(). Those functions are not intended for processing results from prepared statements.

For statements that generate a result set, you can request that mysql_stmt_execute() open a cursor for the statement by calling mysql_stmt_attr_set() before executing the statement. If you execute a statement multiple times, mysql_stmt_execute() closes any open cursor before opening a new one.

Metadata changes to tables or views referred to by prepared statements are detected and cause automatic repreparation of the statement when it is next executed. For more information, see Section 8.10.3, “Caching of Prepared Statements and Stored Programs”.
"""
function execute(stmt::MYSQL_STMT)
    return @checkstmtsuccess stmt mysql_stmt_execute(stmt.ptr)
end

"""
Description
mysql_stmt_fetch() returns the next row in the result set. It can be called only while the result set exists; that is, after a call to mysql_stmt_execute() for a statement such as SELECT that produces a result set.

mysql_stmt_fetch() returns row data using the buffers bound by mysql_stmt_bind_result(). It returns the data in those buffers for all the columns in the current row set and the lengths are returned to the length pointer. All columns must be bound by the application before it calls mysql_stmt_fetch().

mysql_stmt_fetch() typically occurs within a loop, to ensure that all result set rows are fetched. For example:

int status;

while (1)
{
  status = mysql_stmt_fetch(stmt);

  if (status == 1 || status == MYSQL_NO_DATA)
    break;

  /* handle current row here */
}

/* if desired, handle status == 1 case and display error here */
By default, result sets are fetched unbuffered a row at a time from the server. To buffer the entire result set on the client, call mysql_stmt_store_result() after binding the data buffers and before calling mysql_stmt_fetch().

If a fetched data value is a NULL value, the *is_null value of the corresponding MYSQL_BIND structure contains TRUE (1). Otherwise, the data and its length are returned in the *buffer and *length elements based on the buffer type specified by the application. Each numeric and temporal type has a fixed length, as listed in the following table. The length of the string types depends on the length of the actual data value, as indicated by data_length.

Type	Length
MYSQL_TYPE_TINY	1
MYSQL_TYPE_SHORT	2
MYSQL_TYPE_LONG	4
MYSQL_TYPE_LONGLONG	8
MYSQL_TYPE_FLOAT	4
MYSQL_TYPE_DOUBLE	8
MYSQL_TYPE_TIME	sizeof(MYSQL_TIME)
MYSQL_TYPE_DATE	sizeof(MYSQL_TIME)
MYSQL_TYPE_DATETIME	sizeof(MYSQL_TIME)
MYSQL_TYPE_STRING	data length
MYSQL_TYPE_BLOB	data_length
In some cases, you might want to determine the length of a column value before fetching it with mysql_stmt_fetch(). For example, the value might be a long string or BLOB value for which you want to know how much space must be allocated. To accomplish this, use one of these strategies:

Before invoking mysql_stmt_fetch() to retrieve individual rows, pass STMT_ATTR_UPDATE_MAX_LENGTH to mysql_stmt_attr_set(), then invoke mysql_stmt_store_result() to buffer the entire result on the client side. Setting the STMT_ATTR_UPDATE_MAX_LENGTH attribute causes the maximal length of column values to be indicated by the max_length member of the result set metadata returned by mysql_stmt_result_metadata().

Invoke mysql_stmt_fetch() with a zero-length buffer for the column in question and a pointer in which the real length can be stored. Then use the real length with mysql_stmt_fetch_column().

real_length= 0;

bind[0].buffer= 0;
bind[0].buffer_length= 0;
bind[0].length= &real_length
mysql_stmt_bind_result(stmt, bind);

mysql_stmt_fetch(stmt);
if (real_length > 0)
{
  data= malloc(real_length);
  bind[0].buffer= data;
  bind[0].buffer_length= real_length;
  mysql_stmt_fetch_column(stmt, bind, 0, 0);
}
Return Values
Return Value	Description
0	Success, the data has been fetched to application data buffers.
1	Error occurred. Error code and message can be obtained by calling mysql_stmt_errno() and mysql_stmt_error().
MYSQL_NO_DATA	Success, no more data exists
MYSQL_DATA_TRUNCATED	Data truncation occurred
MYSQL_DATA_TRUNCATED is returned when truncation reporting is enabled. To determine which column values were truncated when this value is returned, check the error members of the MYSQL_BIND structures used for fetching values. Truncation reporting is enabled by default, but can be controlled by calling mysql_options() with the MYSQL_REPORT_DATA_TRUNCATION option.
"""
function fetch(stmt::MYSQL_STMT)
    return mysql_stmt_fetch(stmt.ptr)
end

"""
Description
Fetches one column from the current result set row. bind provides the buffer where data should be placed. It should be set up the same way as for mysql_stmt_bind_result(). column indicates which column to fetch. The first column is numbered 0. offset is the offset within the data value at which to begin retrieving data. This can be used for fetching the data value in pieces. The beginning of the value is offset 0.
"""
function fetchcolumn(stmt::MYSQL_STMT, bind::Ptr{Cvoid}, column, offset=0)
    return @checkstmtsuccess stmt mysql_stmt_fetch_column(stmt, bind, column, offset)
end

"""
Description
Returns the number of columns for the most recent statement for the statement handler. This value is zero for statements such as INSERT or DELETE that do not produce result sets.

mysql_stmt_field_count() can be called after you have prepared a statement by invoking mysql_stmt_prepare().
"""
function fieldcount(stmt::MYSQL_STMT)
    return mysql_stmt_field_count(stmt.ptr)
end

"""
Description
Releases memory associated with the result set produced by execution of the prepared statement. If there is a cursor open for the statement, mysql_stmt_free_result() closes it.
"""
function freeresult(stmt::MYSQL_STMT)
    return @checkstmtsuccess stmt mysql_stmt_free_result(stmt.ptr)
end

"""
Description
Creates and returns a MYSQL_STMT handler. The handler should be freed with mysql_stmt_close(), at which point the handler becomes invalid and should no longer be used.

See also Section 28.6.8, “C API Prepared Statement Data Structures”, for more information.

Return Values
A pointer to a MYSQL_STMT structure in case of success. NULL if out of memory.
"""
function stmtinit(mysql::MYSQL)
    return MYSQL_STMT(@checknull mysql mysql_stmt_init(mysql.ptr))
end

"""
Description
Returns the value generated for an AUTO_INCREMENT column by the prepared INSERT or UPDATE statement. Use this function after you have executed a prepared INSERT statement on a table which contains an AUTO_INCREMENT field.

See Section 28.6.6.38, “mysql_insert_id()”, for more information.

Return Values
Value for AUTO_INCREMENT column which was automatically generated or explicitly set during execution of prepared statement, or value generated by LAST_INSERT_ID(expr) function. Return value is undefined if statement does not set AUTO_INCREMENT value.
"""
function insertid(stmt::MYSQL_STMT)
    return mysql_stmt_insert_id(stmt.ptr)
end

"""
Description
This function is used when you use prepared CALL statements to execute stored procedures, which can return multiple result sets. Use a loop that calls mysql_stmt_next_result() to determine whether there are more results. If a procedure has OUT or INOUT parameters, their values will be returned as a single-row result set following any other result sets. The values will appear in the order in which they are declared in the procedure parameter list.

For information about the effect of unhandled conditions on procedure parameters, see Section 13.6.7.8, “Condition Handling and OUT or INOUT Parameters”.

mysql_stmt_next_result() returns a status to indicate whether more results exist. If mysql_stmt_next_result() returns an error, there are no more results.

Before each call to mysql_stmt_next_result(), you must call mysql_stmt_free_result() for the current result if it produced a result set (rather than just a result status).

After calling mysql_stmt_next_result() the state of the connection is as if you had called mysql_stmt_execute(). This means that you can call mysql_stmt_bind_result(), mysql_stmt_affected_rows(), and so forth.

It is also possible to test whether there are more results by calling mysql_more_results(). However, this function does not change the connection state, so if it returns true, you must still call mysql_stmt_next_result() to advance to the next result.

For an example that shows how to use mysql_stmt_next_result(), see Section 28.6.24, “C API Prepared CALL Statement Support”.

Return Values
Return Value	Description
0	Successful and there are more results
-1	Successful and there are no more results
>0	An error occurred

"""
function nextresult(stmt::MYSQL_STMT)
    return mysql_stmt_next_result(stmt.ptr)
end

"""
Description
Returns the number of rows in the result set.

The use of mysql_stmt_num_rows() depends on whether you used mysql_stmt_store_result() to buffer the entire result set in the statement handler. If you use mysql_stmt_store_result(), mysql_stmt_num_rows() may be called immediately. Otherwise, the row count is unavailable unless you count the rows as you fetch them.

mysql_stmt_num_rows() is intended for use with statements that return a result set, such as SELECT. For statements such as INSERT, UPDATE, or DELETE, the number of affected rows can be obtained with mysql_stmt_affected_rows().

Return Values
The number of rows in the result set.
"""
function numrows(stmt::MYSQL_STMT)
    return mysql_stmt_num_rows(stmt.ptr)
end

"""
Description
Returns the number of parameter markers present in the prepared statement.

Return Values
An unsigned long integer representing the number of parameters in a statement.
"""
function paramcount(stmt::MYSQL_STMT)
    return mysql_stmt_param_count(stmt.ptr)
end

"""
Description
Given the statement handler returned by mysql_stmt_init(), prepares the SQL statement pointed to by the string stmt_str and returns a status value. The string length should be given by the length argument. The string must consist of a single SQL statement. You should not add a terminating semicolon (;) or \\g to the statement.

The application can include one or more parameter markers in the SQL statement by embedding question mark (?) characters into the SQL string at the appropriate positions.

The markers are legal only in certain places in SQL statements. For example, they are permitted in the VALUES() list of an INSERT statement (to specify column values for a row), or in a comparison with a column in a WHERE clause to specify a comparison value. However, they are not permitted for identifiers (such as table or column names), or to specify both operands of a binary operator such as the = equal sign. The latter restriction is necessary because it would be impossible to determine the parameter type. In general, parameters are legal only in Data Manipulation Language (DML) statements, and not in Data Definition Language (DDL) statements.

The parameter markers must be bound to application variables using mysql_stmt_bind_param() before executing the statement.

Metadata changes to tables or views referred to by prepared statements are detected and cause automatic repreparation of the statement when it is next executed. For more information, see Section 8.10.3, “Caching of Prepared Statements and Stored Programs”.
"""
function prepare(stmt::MYSQL_STMT, sql::String)
    return @checkstmtsuccess stmt mysql_stmt_prepare(stmt.ptr, sql, sizeof(sql))
end

"""
Description
Resets a prepared statement on client and server to state after prepare. It resets the statement on the server, data sent using mysql_stmt_send_long_data(), unbuffered result sets and current errors. It does not clear bindings or stored result sets. Stored result sets will be cleared when executing the prepared statement (or closing it).

To re-prepare the statement with another query, use mysql_stmt_prepare().
"""
function reset(stmt::MYSQL_STMT)
    return @checkstmtsuccess stmt mysql_stmt_reset(stmt.ptr)
end

"""
Description
If a statement passed to mysql_stmt_prepare() is one that produces a result set, mysql_stmt_result_metadata() returns the result set metadata in the form of a pointer to a MYSQL_RES structure that can be used to process the meta information such as number of fields and individual field information. This result set pointer can be passed as an argument to any of the field-based API functions that process result set metadata, such as:

mysql_num_fields()

mysql_fetch_field()

mysql_fetch_field_direct()

mysql_fetch_fields()

mysql_field_count()

mysql_field_seek()

mysql_field_tell()

mysql_free_result()

The result set structure should be freed when you are done with it, which you can do by passing it to mysql_free_result(). This is similar to the way you free a result set obtained from a call to mysql_store_result().

The result set returned by mysql_stmt_result_metadata() contains only metadata. It does not contain any row results. The rows are obtained by using the statement handler with mysql_stmt_fetch().

Return Values
A MYSQL_RES result structure. NULL if no meta information exists for the prepared query.
"""
function resultmetadata(stmt::MYSQL_STMT)
    return MYSQL_RES(mysql_stmt_result_metadata(stmt.ptr))
end

"""
Description
Sets the row cursor to an arbitrary row in a statement result set. The offset value is a row offset that should be a value returned from mysql_stmt_row_tell() or from mysql_stmt_row_seek(). This value is not a row number; if you want to seek to a row within a result set by number, use mysql_stmt_data_seek() instead.

This function requires that the result set structure contains the entire result of the query, so mysql_stmt_row_seek() may be used only in conjunction with mysql_stmt_store_result().

Return Values
The previous value of the row cursor. This value may be passed to a subsequent call to mysql_stmt_row_seek().
"""
function rowseek(stmt::MYSQL_STMT, offset::Ptr{Cvoid})
    return mysql_stmt_row_seek(stmt.ptr, offset)
end

"""
Description
Returns the current position of the row cursor for the last mysql_stmt_fetch(). This value can be used as an argument to mysql_stmt_row_seek().

You should use mysql_stmt_row_tell() only after mysql_stmt_store_result().

Return Values
The current offset of the row cursor.
"""
function rowtell(stmt::MYSQL_STMT)
    return mysql_stmt_row_tell(stmt.ptr)
end

"""
Description
Enables an application to send parameter data to the server in pieces (or “chunks”). Call this function after mysql_stmt_bind_param() and before mysql_stmt_execute(). It can be called multiple times to send the parts of a character or binary data value for a column, which must be one of the TEXT or BLOB data types.

parameter_number indicates which parameter to associate the data with. Parameters are numbered beginning with 0. data is a pointer to a buffer containing data to be sent, and length indicates the number of bytes in the buffer.

Note
The next mysql_stmt_execute() call ignores the bind buffer for all parameters that have been used with mysql_stmt_send_long_data() since last mysql_stmt_execute() or mysql_stmt_reset().

If you want to reset/forget the sent data, you can do it with mysql_stmt_reset(). See Section 28.6.10.22, “mysql_stmt_reset()”.

The max_allowed_packet system variable controls the maximum size of parameter values that can be sent with mysql_stmt_send_long_data().
"""
function sendlongdata(stmt::MYSQL_STMT, parameter_number, data::Union{String, Vector{UInt8}})
    return @checkstmtsuccess stmt mysql_stmt_send_long_data(stmt.ptr, parameter_number, data isa Vector ? pointer(data) : data, data isa Vector ? length(data) : sizeof(data))
end

"""
Description
For the statement specified by stmt, mysql_stmt_sqlstate() returns a null-terminated string containing the SQLSTATE error code for the most recently invoked prepared statement API function that can succeed or fail. The error code consists of five characters. "00000" means “no error.” The values are specified by ANSI SQL and ODBC. For a list of possible values, see Appendix B, Errors, Error Codes, and Common Problems.

Not all MySQL errors are mapped to SQLSTATE codes. The value "HY000" (general error) is used for unmapped errors.

If the failed statement API function was mysql_stmt_close(), do not call mysql_stmt_sqlstate() to obtain error information because mysql_stmt_close() makes the statement handler invalid. Call mysql_sqlstate() instead.

Return Values
A null-terminated character string containing the SQLSTATE error code.
"""
function sqlstate(stmt::MYSQL_STMT)
    return unsafe_string(mysql_stmt_sqlstate(stmt.ptr))
end

"""
Description
Result sets are produced by calling mysql_stmt_execute() to executed prepared statements for SQL statements such as SELECT, SHOW, DESCRIBE, and EXPLAIN. By default, result sets for successfully executed prepared statements are not buffered on the client and mysql_stmt_fetch() fetches them one at a time from the server. To cause the complete result set to be buffered on the client, call mysql_stmt_store_result() after binding data buffers with mysql_stmt_bind_result() and before calling mysql_stmt_fetch() to fetch rows. (For an example, see Section 28.6.10.11, “mysql_stmt_fetch()”.)

mysql_stmt_store_result() is optional for result set processing, unless you will call mysql_stmt_data_seek(), mysql_stmt_row_seek(), or mysql_stmt_row_tell(). Those functions require a seekable result set.

It is unnecessary to call mysql_stmt_store_result() after executing an SQL statement that does not produce a result set, but if you do, it does not harm or cause any notable performance problem. You can detect whether the statement produced a result set by checking if mysql_stmt_result_metadata() returns NULL. For more information, refer to Section 28.6.10.23, “mysql_stmt_result_metadata()”.

Note
MySQL does not by default calculate MYSQL_FIELD->max_length for all columns in mysql_stmt_store_result() because calculating this would slow down mysql_stmt_store_result() considerably and most applications do not need max_length. If you want max_length to be updated, you can call mysql_stmt_attr_set(MYSQL_STMT, STMT_ATTR_UPDATE_MAX_LENGTH, &flag) to enable this. See Section 28.6.10.3, “mysql_stmt_attr_set()”.
"""
function storeresult(stmt::MYSQL_STMT)
    return @checkstmtsuccess stmt mysql_stmt_store_result(stmt.ptr)
end
