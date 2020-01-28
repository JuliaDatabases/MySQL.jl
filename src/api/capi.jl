macro checksuccess(mysql, code)
    return esc(quote
        result = $code
        result != 0 && throw(Error($mysql))
        result
    end)
end

macro checknull(mysql, ptr)
    return esc(quote
        result = $ptr
        result == C_NULL && throw(Error($mysql))
        result
    end)
end

#="""
Description
mysql_affected_rows() may be called immediately after executing a statement with mysql_query() or mysql_real_query(). It returns the number of rows changed, deleted, or inserted by the last statement if it was an UPDATE, DELETE, or INSERT. For SELECT statements, mysql_affected_rows() works like mysql_num_rows().

For UPDATE statements, the affected-rows value by default is the number of rows actually changed. If you specify the CLIENT_FOUND_ROWS flag to mysql_real_connect() when connecting to mysqld, the affected-rows value is the number of rows “found”; that is, matched by the WHERE clause.

For REPLACE statements, the affected-rows value is 2 if the new row replaced an old row, because in this case, one row was inserted after the duplicate was deleted.

For INSERT ... ON DUPLICATE KEY UPDATE statements, the affected-rows value per row is 1 if the row is inserted as a new row, 2 if an existing row is updated, and 0 if an existing row is set to its current values. If you specify the CLIENT_FOUND_ROWS flag, the affected-rows value is 1 (not 0) if an existing row is set to its current values.

Following a CALL statement for a stored procedure, mysql_affected_rows() returns the value that it would return for the last statement executed within the procedure, or 0 if that statement would return -1. Within the procedure, you can use ROW_COUNT() at the SQL level to obtain the affected-rows value for individual statements.

mysql_affected_rows() returns a meaningful value for a wide range of statements. For details, see the description for ROW_COUNT() in Section 12.15, “Information Functions”.

Return Values
An integer greater than zero indicates the number of rows affected or retrieved. Zero indicates that no records were updated for an UPDATE statement, no rows matched the WHERE clause in the query or that no query has yet been executed. -1 indicates that the query returned an error or that, for a SELECT query, mysql_affected_rows() was called prior to calling mysql_store_result().

Because mysql_affected_rows() returns an unsigned value, you can check for -1 by comparing the return value to (uint64_t)-1 (or to (uint64_t)~0, which is equivalent).

Errors
None.
"""=#
function affectedrows(mysql::MYSQL)
    mysql_affected_rows(mysql.ptr)
end

#="""
Description
Sets autocommit mode on if mode is 1, off if mode is 0.

Return Values
Zero for success. Nonzero if an error occurred.

Errors
None.
"""=#
function autocommit(mysql::MYSQL, mode::Bool)
    return @checksuccess mysql mysql_autocommit(mysql.ptr, mode)
end

#="""
Description
Changes the user and causes the database specified by db to become the default (current) database on the connection specified by mysql. In subsequent queries, this database is the default for table references that include no explicit database specifier.

mysql_change_user() fails if the connected user cannot be authenticated or does not have permission to use the database. In this case, the user and database are not changed.

Pass a db parameter of NULL if you do not want to have a default database.

This function resets the session state as if one had done a new connect and reauthenticated. (See Section 28.6.27, “C API Automatic Reconnection Control”.) It always performs a ROLLBACK of any active transactions, closes and drops all temporary tables, and unlocks all locked tables. Session system variables are reset to the values of the corresponding global system variables. Prepared statements are released and HANDLER variables are closed. Locks acquired with GET_LOCK() are released. These effects occur even if the user did not change.

To reset the connection state in a more lightweight manner without changing the user, use mysql_reset_connection().

Return Values
Zero for success. Nonzero if an error occurred.

Errors
The same that you can get from mysql_real_connect(), plus:

CR_COMMANDS_OUT_OF_SYNC

Commands were executed in an improper order.

CR_SERVER_GONE_ERROR

The MySQL server has gone away.

CR_SERVER_LOST

The connection to the server was lost during the query.

CR_UNKNOWN_ERROR

An unknown error occurred.

ER_UNKNOWN_COM_ERROR

The MySQL server does not implement this command (probably an old server).

ER_ACCESS_DENIED_ERROR

The user or password was wrong.

ER_BAD_DB_ERROR

The database did not exist.

ER_DBACCESS_DENIED_ERROR

The user did not have access rights to the database.

ER_WRONG_DB_NAME

The database name was too long.
"""=#
function changeuser(mysql::MYSQL, user::String, password::String, db::String)
    return @checksuccess mysql mysql_change_user(mysql.ptr, user, password, isempty(db) ? C_NULL : db)
end

#="""
Description
Returns the default character set name for the current connection.

Return Values
The default character set name

Errors
None.
"""=#
function charactersetname(mysql::MYSQL)
    return unsafe_string(mysql_character_set_name(mysql.ptr))
end

#="""
Returns a pointer to a loaded plugin, loading the plugin first if necessary. An error occurs if the type is invalid or the plugin cannot be found or loaded.

Specify the parameters as follows:

mysql: A pointer to a MYSQL structure. The plugin API does not require a connection to a MySQL server, but this structure must be properly initialized. The structure is used to obtain connection-related information.

name: The plugin name.

type: The plugin type.
"""=#
function findplugin(mysql::MYSQL, name::String, type::Integer)
    return @checknull mysql mysql_client_find_plugin(mysql.ptr, name, type)
end

#="""
Adds a plugin structure to the list of loaded plugins. An error occurs if the plugin is already loaded.

Specify the parameters as follows:

mysql: A pointer to a MYSQL structure. The plugin API does not require a connection to a MySQL server, but this structure must be properly initialized. The structure is used to obtain connection-related information.

plugin: A pointer to the plugin structure.
"""=#
function registerplugin(mysql::MYSQL, plugin::Ptr{Cvoid})
    return @checknull mysql mysql_client_register_plugin(mysql.ptr, plugin)
end

#="""
Description
Closes a previously opened connection. mysql_close() also deallocates the connection handler pointed to by mysql if the handler was allocated automatically by mysql_init() or mysql_connect(). Do not use the handler after it has been closed.

Return Values
None.

Errors
None.
"""=#
function close(mysql::MYSQL)
    mysql_close(mysql.ptr)
    return
end

#="""
Commits the current transaction.

The action of this function is subject to the value of the completion_type system variable. In particular, if the value of completion_type is RELEASE (or 2), the server performs a release after terminating a transaction and closes the client connection. Call mysql_close() from the client program to close the connection from the client side.
"""=#
function commit(mysql::MYSQL)
    return @checksuccess mysql mysql_commit(mysql.ptr)
end

#="""
Seeks to an arbitrary row in a query result set. The offset value is a row number. Specify a value in the range from 0 to mysql_num_rows(result)-1.

This function requires that the result set structure contains the entire result of the query, so mysql_data_seek() may be used only in conjunction with mysql_store_result(), not with mysql_use_result().
"""=#
function dataseek(result::MYSQL_RES, offset::Integer)
    return mysql_data_seek(result.ptr, offset)
end

"""
Instructs the server to write debugging information to the error log. The connected user must have the SUPER privilege.
"""
function dumpdebuginfo(mysql::MYSQL)
    return @checksuccess mysql mysql_dump_debug_info(mysql.ptr)
end

#="""
Description
For the connection specified by mysql, mysql_errno() returns the error code for the most recently invoked API function that can succeed or fail. A return value of zero means that no error occurred. Client error message numbers are listed in the MySQL errmsg.h header file. Server error message numbers are listed in mysqld_error.h. Errors also are listed at Appendix B, Errors, Error Codes, and Common Problems.

Note
Some functions such as mysql_fetch_row() do not set mysql_errno() if they succeed. A rule of thumb is that all functions that have to ask the server for information reset mysql_errno() if they succeed.

MySQL-specific error numbers returned by mysql_errno() differ from SQLSTATE values returned by mysql_sqlstate(). For example, the mysql client program displays errors using the following format, where 1146 is the mysql_errno() value and '42S02' is the corresponding mysql_sqlstate() value:

shell> SELECT * FROM no_such_table;
ERROR 1146 (42S02): Table 'test.no_such_table' doesn't exist
Return Values
An error code value for the last mysql_xxx() call, if it failed. zero means no error occurred.
"""=#
function errno(mysql::MYSQL)
    return API.mysql_errno(mysql.ptr)
end

#="""
Description
For the connection specified by mysql, mysql_error() returns a null-terminated string containing the error message for the most recently invoked API function that failed. If a function did not fail, the return value of mysql_error() may be the previous error or an empty string to indicate no error.

A rule of thumb is that all functions that have to ask the server for information reset mysql_error() if they succeed.

For functions that reset mysql_error(), either of these two tests can be used to check for an error:

if(*mysql_error(&mysql))
{
  // an error occurred
}

if(mysql_error(&mysql)[0])
{
  // an error occurred
}
The language of the client error messages may be changed by recompiling the MySQL client library. You can choose error messages in several different languages. See Section 10.12, “Setting the Error Message Language”.

Return Values
A null-terminated character string that describes the error. An empty string if no error occurred.

Errors
None.
"""=#
function errormsg(mysql::MYSQL)
    return unsafe_string(API.mysql_error(mysql.ptr))
end

#="""
Returns the definition of one column of a result set as a MYSQL_FIELD structure. Call this function repeatedly to retrieve information about all columns in the result set. mysql_fetch_field() returns NULL when no more fields are left.

For metadata-optional connections, this function returns NULL when the resultset_metadata system variable is set to NONE. To check whether a result set has metadata, use the mysql_result_metadata() function. For details about managing result set metadata transfer, see Section 28.6.26, “C API Optional Result Set Metadata”.

mysql_fetch_field() is reset to return information about the first field each time you execute a new SELECT query. The field returned by mysql_fetch_field() is also affected by calls to mysql_field_seek().

If you've called mysql_query() to perform a SELECT on a table but have not called mysql_store_result(), MySQL returns the default blob length (8KB) if you call mysql_fetch_field() to ask for the length of a BLOB field. (The 8KB size is chosen because MySQL does not know the maximum length for the BLOB. This should be made configurable sometime.) Once you've retrieved the result set, field->max_length contains the length of the largest value for this column in the specific query.
"""=#
function fetchfield(result::MYSQL_RES)
    fieldptr = convert(Ptr{MYSQL_FIELD}, mysql_fetch_field(result.ptr))
    return fieldptr == C_NULL ? nothing : unsafe_load(fieldptr)
end

#="""
Given a field number fieldnr for a column within a result set, returns that column's field definition as a MYSQL_FIELD structure. Use this function to retrieve the definition for an arbitrary column. Specify a value for fieldnr in the range from 0 to mysql_num_fields(result)-1.

For metadata-optional connections, this function returns NULL when the resultset_metadata system variable is set to NONE. To check whether a result set has metadata, use the mysql_result_metadata() function. For details about managing result set metadata transfer, see Section 28.6.26, “C API Optional Result Set Metadata”.
"""=#
function fetchfielddirect(result::MYSQL_RES, fieldnr::Integer)
    fieldptr = convert(Ptr{MYSQL_FIELD}, mysql_fetch_field_direct(result.ptr, fieldnr))
    return fieldptr == C_NULL ? nothing : unsafe_load(fieldptr)
end

#="""
Description
Returns an array of all MYSQL_FIELD structures for a result set. Each structure provides the field definition for one column of the result set.

For metadata-optional connections, this function returns NULL when the resultset_metadata system variable is set to NONE. To check whether a result set has metadata, use the mysql_result_metadata() function. For details about managing result set metadata transfer, see Section 28.6.26, “C API Optional Result Set Metadata”.

Return Values
An array of MYSQL_FIELD structures for all columns of a result set. NULL if the result set has no metadata.
"""=#
function fetchfields(result::MYSQL_RES, nfields::Integer)
    fieldsptr = convert(Ptr{MYSQL_FIELD}, mysql_fetch_fields(result.ptr))
    return fieldsptr == C_NULL ? nothing : unsafe_wrap(Array, fieldsptr, nfields)
end

#="""
Description
Returns the lengths of the columns of the current row within a result set. If you plan to copy field values, this length information is also useful for optimization, because you can avoid calling strlen(). In addition, if the result set contains binary data, you must use this function to determine the size of the data, because strlen() returns incorrect results for any field containing null characters.

The length for empty columns and for columns containing NULL values is zero. To see how to distinguish these two cases, see the description for mysql_fetch_row().

Return Values
An array of unsigned long integers representing the size of each column (not including any terminating null bytes). NULL if an error occurred.
"""=#
function fetchlengths(result::MYSQL_RES, nfields::Integer)
    lensptr = mysql_fetch_lengths(result.ptr)
    return unsafe_wrap(Array, lensptr, nfields)
end

#="""
mysql_fetch_row() retrieves the next row of a result set:

When used after mysql_store_result() or mysql_store_result_nonblocking(), mysql_fetch_row() returns NULL if there are no more rows to retrieve.

When used after mysql_use_result(), mysql_fetch_row() returns NULL if there are no more rows to retrieve or an error occurred.

The number of values in the row is given by mysql_num_fields(result). If row holds the return value from a call to mysql_fetch_row(), pointers to the values are accessed as row[0] to row[mysql_num_fields(result)-1]. NULL values in the row are indicated by NULL pointers.

The lengths of the field values in the row may be obtained by calling mysql_fetch_lengths(). Empty fields and fields containing NULL both have length 0; you can distinguish these by checking the pointer for the field value. If the pointer is NULL, the field is NULL; otherwise, the field is empty.

Return Values
A MYSQL_ROW structure for the next row, or NULL. The meaning of a NULL return depends on which function was called preceding mysql_fetch_row():

When used after mysql_store_result() or mysql_store_result_nonblocking(), mysql_fetch_row() returns NULL if there are no more rows to retrieve.

When used after mysql_use_result(), mysql_fetch_row() returns NULL if there are no more rows to retrieve or an error occurred. To determine whether an error occurred, check whether mysql_error() returns a nonempty string or mysql_errno() returns nonzero.
"""=#
function fetchrow(mysql::MYSQL, result::MYSQL_RES)
    values = mysql_fetch_row(result.ptr)
    # if values == C_NULL
    #     @checksuccess mysql mysql_errno(mysql.ptr)
    #     return nothing
    # end
    return values
end

#="""
Description
Returns the number of columns for the most recent query on the connection.

The normal use of this function is when mysql_store_result() returned NULL (and thus you have no result set pointer). In this case, you can call mysql_field_count() to determine whether mysql_store_result() should have produced a nonempty result. This enables the client program to take proper action without knowing whether the query was a SELECT (or SELECT-like) statement. The example shown here illustrates how this may be done.

See Section 28.6.28.1, “Why mysql_store_result() Sometimes Returns NULL After mysql_query() Returns Success”.

Return Values
An unsigned integer representing the number of columns in a result set.
"""=#
function fieldcount(mysql::MYSQL)
    return mysql_field_count(mysql.ptr)
end

#="""
Description
Sets the field cursor to the given offset. The next call to mysql_fetch_field() retrieves the field definition of the column associated with that offset.

To seek to the beginning of a row, pass an offset value of zero.

Return Values
The previous value of the field cursor.
"""=#
function fieldseek(result::MYSQL_RES, offset::Integer)
    return mysql_field_seek(result.ptr, offset)
end

#="""
Description
Returns the position of the field cursor used for the last mysql_fetch_field(). This value can be used as an argument to mysql_field_seek().

Return Values
The current offset of the field cursor.
"""=#
function fieldtell(result::MYSQL_RES)
    return mysql_field_tell(result.ptr)
end

#="""
mysql_free_result() frees the memory allocated for a result set by mysql_store_result(), mysql_use_result(), mysql_list_dbs(), and so forth. When you are done with a result set, you must free the memory it uses by calling mysql_free_result().

Do not attempt to access a result set after freeing it.
"""=#
function freeresult(result::MYSQL_RES)
    mysql_free_result(result.ptr)
    return
end

#="""
This function provides information about the default client character set. The default character set may be changed with the mysql_set_character_set() function.
"""=#
function getcharactersetinfo(mysql::MYSQL)
    cs = Ref{MY_CHARSET_INFO}()
    mysql_get_character_set_info(mysql.ptr, cs)
    return cs[]
end

#="""
Description
Returns a string that represents the MySQL client library version (for example, "8.0.20").

The function value is the version of MySQL that provides the client library. For more information, see Section 28.6.3.5, “C API Server Version and Client Library Version”.

Return Values
A character string that represents the MySQL client library version.
"""=#
function getclientinfo()
    return unsafe_string(mysql_get_client_info())
end

#="""
Returns an integer that represents the MySQL client library version. The value has the format XYYZZ where X is the major version, YY is the release level (or minor version), and ZZ is the sub-version within the release level:

major_version*10000 + release_level*100 + sub_version
For example, "8.0.20" is returned as 80020.

The function value is the version of MySQL that provides the client library. For more information, see Section 28.6.3.5, “C API Server Version and Client Library Version”.

Return Values
An integer that represents the MySQL client library version.
"""=#
function getclientversion()
    return mysql_get_client_version()
end

"""
Returns a string describing the type of connection in use, including the server host name.
"""
function gethostinfo(mysql::MYSQL)
    return unsafe_string(mysql_get_host_info(mysql.ptr))
end

#="""
Description
Returns the current value of an option settable using mysql_options(). The value should be treated as read only.

The option argument is the option for which you want its value. The arg argument is a pointer to a variable in which to store the option value. arg must be a pointer to a variable of the type appropriate for the option argument. The following table shows which variable type to use for each option value.

arg Type	Applicable option Values
unsigned int	MYSQL_OPT_CONNECT_TIMEOUT, MYSQL_OPT_PROTOCOL, MYSQL_OPT_READ_TIMEOUT, MYSQL_OPT_RETRY_COUNT, MYSQL_OPT_SSL_FIPS_MODE, MYSQL_OPT_SSL_MODE, MYSQL_OPT_WRITE_TIMEOUT, MYSQL_OPT_ZSTD_COMPRESSION_LEVEL
unsigned long	MYSQL_OPT_MAX_ALLOWED_PACKET, MYSQL_OPT_NET_BUFFER_LENGTH
bool	MYSQL_ENABLE_CLEARTEXT_PLUGIN, MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS, MYSQL_OPT_GET_SERVER_PUBLIC_KEY, MYSQL_OPT_LOCAL_INFILE, MYSQL_OPT_OPTIONAL_RESULTSET_METADATA, MYSQL_OPT_RECONNECT, MYSQL_REPORT_DATA_TRUNCATION
const char *	MYSQL_DEFAULT_AUTH, MYSQL_OPT_BIND, MYSQL_OPT_COMPRESSION_ALGORITHMS, MYSQL_OPT_SSL_CA, MYSQL_OPT_SSL_CAPATH, MYSQL_OPT_SSL_CERT, MYSQL_OPT_SSL_CIPHER, MYSQL_OPT_SSL_CRL, MYSQL_OPT_SSL_CRLPATH, MYSQL_OPT_SSL_KEY, MYSQL_OPT_TLS_CIPHERSUITES, MYSQL_OPT_TLS_VERSION, MYSQL_PLUGIN_DIR, MYSQL_READ_DEFAULT_FILE, MYSQL_READ_DEFAULT_GROUP, MYSQL_SERVER_PUBLIC_KEY, MYSQL_SET_CHARSET_DIR, MYSQL_SET_CHARSET_NAME, MYSQL_SHARED_MEMORY_BASE_NAME
argument not used	MYSQL_OPT_COMPRESS
cannot be queried (error is returned)	MYSQL_INIT_COMMAND, MYSQL_OPT_CONNECT_ATTR_DELETE, MYSQL_OPT_CONNECT_ATTR_RESET, MYSQL_OPT_NAMED_PIPE
Return Values
Zero for success. Nonzero if an error occurred; this occurs for option values that cannot be queried.
"""=#
function getoption(mysql::MYSQL, option::mysql_option)
    if option in CUINTOPTS
        arg = Ref{Cuint}()
    elseif option in CULONGOPTS
        arg = Ref{Culong}()
    elseif option in BOOLOPTS
        arg = Ref{Bool}()
    else
        arg = Ref{String}()
    end
    return @checksuccess mysql mysql_get_option(mysql.ptr, option, arg)
end

#="""
Description
Returns the protocol version used by current connection.

Return Values
An unsigned integer representing the protocol version used by the current connection.

Errors
None.
"""=#
function getprotoinfo(mysql::MYSQL)
    return mysql_get_proto_info(mysql.ptr)
end

"""
Returns a string that represents the MySQL server version (for example, \"8.0.20\").
"""
function getserverinfo(mysql::MYSQL)
    return unsafe_string(mysql_get_server_info(mysql.ptr))
end

#="""
Returns an integer that represents the MySQL server version. The value has the format XYYZZ where X is the major version, YY is the release level (or minor version), and ZZ is the sub-version within the release level:

major_version*10000 + release_level*100 + sub_version
For example, "8.0.20" is returned as 80020.

This function is useful in client programs for determining whether some version-specific server capability exists.
"""=#
function getserverversion(mysql::MYSQL)
    return mysql_get_server_version()
end

#="""
Description
mysql_get_ssl_cipher() returns the encryption cipher used for the given connection to the server. mysql is the connection handler returned from mysql_init().

Return Values
A string naming the encryption cipher used for the connection, or NULL if the connection is not encrypted.
"""=#
function getsslcipher(mysql::MYSQL)
    return unsafe_string(mysql_get_ssl_cipher(mysql.ptr))
end

#="""
Description
This function creates a legal SQL string for use in an SQL statement. See Section 9.1.1, “String Literals”.

The string in the from argument is encoded in hexadecimal format, with each character encoded as two hexadecimal digits. The result is placed in the to argument, followed by a terminating null byte.

The string pointed to by from must be length bytes long. You must allocate the to buffer to be at least length*2+1 bytes long. When mysql_hex_string() returns, the contents of to is a null-terminated string. The return value is the length of the encoded string, not including the terminating null byte.

The return value can be placed into an SQL statement using either X'value' or 0xvalue format. However, the return value does not include the X'...' or 0x. The caller must supply whichever of those is desired.

Example
char query[1000],*end;

end = strmov(query,"INSERT INTO test_table values(");
end = strmov(end,"X'");
end += mysql_hex_string(end,"What is this",12);
end = strmov(end,"',X'");
end += mysql_hex_string(end,"binary data: \0\r\n",16);
end = strmov(end,"')");

if (mysql_real_query(&mysql,query,(unsigned int) (end - query)))
{
   fprintf(stderr, "Failed to insert row, Error: %s\n",
           mysql_error(&mysql));
}
The strmov() function used in the example is included in the libmysqlclient library and works like strcpy() but returns a pointer to the terminating null of the first parameter.

Return Values
The length of the encoded string that is placed into to, not including the terminating null character.
"""=#
function hexstring(from::String)
    len = sizeof(from)
    to = Base.StringVector(len * 2 + 1)
    tolen = mysql_hex_string(to, from, len)
    resize!(to, tolen)
    return String(to)
end

#="""
Description
Retrieves a string providing information about the most recently executed statement, but only for the statements listed here. For other statements, mysql_info() returns NULL. The format of the string varies depending on the type of statement, as described here. The numbers are illustrative only; the string contains values appropriate for the statement.

INSERT INTO ... SELECT ...

String format: Records: 100 Duplicates: 0 Warnings: 0

INSERT INTO ... VALUES (...),(...),(...)...

String format: Records: 3 Duplicates: 0 Warnings: 0

LOAD DATA

String format: Records: 1 Deleted: 0 Skipped: 0 Warnings: 0

ALTER TABLE

String format: Records: 3 Duplicates: 0 Warnings: 0

UPDATE

String format: Rows matched: 40 Changed: 40 Warnings: 0

mysql_info() returns a non-NULL value for INSERT ... VALUES only for the multiple-row form of the statement (that is, only if multiple value lists are specified).

Return Values
A character string representing additional information about the most recently executed statement. NULL if no information is available for the statement.
"""=#
function info(mysql::MYSQL)
    str = mysql_info(mysql.ptr)
    return str == C_NULL ? "" : unsafe_string(str)
end

#="""
Description
Allocates or initializes a MYSQL object suitable for mysql_real_connect(). If mysql is a NULL pointer, the function allocates, initializes, and returns a new object. Otherwise, the object is initialized and the address of the object is returned. If mysql_init() allocates a new object, it is freed when mysql_close() is called to close the connection.

In a nonmultithreaded environment, mysql_init() invokes mysql_library_init() automatically as necessary. However, mysql_library_init() is not thread-safe in a multithreaded environment, and thus neither is mysql_init(). Before calling mysql_init(), either call mysql_library_init() prior to spawning any threads, or use a mutex to protect the mysql_library_init() call. This should be done prior to any other client library call.

Return Values
An initialized MYSQL* handler. NULL if there was insufficient memory to allocate a new object.

Errors
In case of insufficient memory, NULL is returned.
"""=#
function init()
    return MYSQL(mysql_init(C_NULL))
end

#="""
Description
Returns the value generated for an AUTO_INCREMENT column by the previous INSERT or UPDATE statement. Use this function after you have performed an INSERT statement into a table that contains an AUTO_INCREMENT field, or have used INSERT or UPDATE to set a column value with LAST_INSERT_ID(expr).

The return value of mysql_insert_id() is always zero unless explicitly updated under one of the following conditions:

INSERT statements that store a value into an AUTO_INCREMENT column. This is true whether the value is automatically generated by storing the special values NULL or 0 into the column, or is an explicit nonspecial value.

In the case of a multiple-row INSERT statement, mysql_insert_id() returns the first automatically generated AUTO_INCREMENT value that was successfully inserted.

If no rows are successfully inserted, mysql_insert_id() returns 0.

If an INSERT ... SELECT statement is executed, and no automatically generated value is successfully inserted, mysql_insert_id() returns the ID of the last inserted row.

If an INSERT ... SELECT statement uses LAST_INSERT_ID(expr), mysql_insert_id() returns expr.

INSERT statements that generate an AUTO_INCREMENT value by inserting LAST_INSERT_ID(expr) into any column or by updating any column to LAST_INSERT_ID(expr).

If the previous statement returned an error, the value of mysql_insert_id() is undefined.

The return value of mysql_insert_id() can be simplified to the following sequence:

If there is an AUTO_INCREMENT column, and an automatically generated value was successfully inserted, return the first such value.

If LAST_INSERT_ID(expr) occurred in the statement, return expr, even if there was an AUTO_INCREMENT column in the affected table.

The return value varies depending on the statement used. When called after an INSERT statement:

If there is an AUTO_INCREMENT column in the table, and there were some explicit values for this column that were successfully inserted into the table, return the last of the explicit values.

When called after an INSERT ... ON DUPLICATE KEY UPDATE statement:

If there is an AUTO_INCREMENT column in the table and there were some explicit successfully inserted values or some updated values, return the last of the inserted or updated values.

mysql_insert_id() returns 0 if the previous statement does not use an AUTO_INCREMENT value. If you must save the value for later, be sure to call mysql_insert_id() immediately after the statement that generates the value.

The value of mysql_insert_id() is affected only by statements issued within the current client connection. It is not affected by statements issued by other clients.

The LAST_INSERT_ID() SQL function will contain the value of the first automatically generated value that was successfully inserted. LAST_INSERT_ID() is not reset between statements because the value of that function is maintained in the server. Another difference from mysql_insert_id() is that LAST_INSERT_ID() is not updated if you set an AUTO_INCREMENT column to a specific nonspecial value. See Section 12.15, “Information Functions”.

mysql_insert_id() returns 0 following a CALL statement for a stored procedure that generates an AUTO_INCREMENT value because in this case mysql_insert_id() applies to CALL and not the statement within the procedure. Within the procedure, you can use LAST_INSERT_ID() at the SQL level to obtain the AUTO_INCREMENT value.

The reason for the differences between LAST_INSERT_ID() and mysql_insert_id() is that LAST_INSERT_ID() is made easy to use in scripts while mysql_insert_id() tries to provide more exact information about what happens to the AUTO_INCREMENT column.
"""=#
function insertid(mysql::MYSQL)
    return mysql_insert_id(mysql.ptr)
end

#="""
Description
This function is used when you execute multiple statements specified as a single statement string, or when you execute CALL statements, which can return multiple result sets.

mysql_more_results() true if more results exist from the currently executed statement, in which case the application must call mysql_next_result() to fetch the results.

Return Values
TRUE (1) if more results exist. FALSE (0) if no more results exist.

In most cases, you can call mysql_next_result() instead to test whether more results exist and initiate retrieval if so.
"""=#
function moreresults(mysql::MYSQL)
    return mysql_more_results(mysql.ptr)
end

#="""
mysql_next_result() is used when you execute multiple statements specified as a single statement string, or when you use CALL statements to execute stored procedures, which can return multiple result sets.

mysql_next_result() reads the next statement result and returns a status to indicate whether more results exist. If mysql_next_result() returns an error, there are no more results.

Before each call to mysql_next_result(), you must call mysql_free_result() for the current statement if it is a statement that returned a result set (rather than just a result status).

After calling mysql_next_result() the state of the connection is as if you had called mysql_real_query() or mysql_query() for the next statement. This means that you can call mysql_store_result(), mysql_warning_count(), mysql_affected_rows(), and so forth.

If your program uses CALL statements to execute stored procedures, the CLIENT_MULTI_RESULTS flag must be enabled. This is because each CALL returns a result to indicate the call status, in addition to any result sets that might be returned by statements executed within the procedure. Because CALL can return multiple results, process them using a loop that calls mysql_next_result() to determine whether there are more results.

CLIENT_MULTI_RESULTS can be enabled when you call mysql_real_connect(), either explicitly by passing the CLIENT_MULTI_RESULTS flag itself, or implicitly by passing CLIENT_MULTI_STATEMENTS (which also enables CLIENT_MULTI_RESULTS). CLIENT_MULTI_RESULTS is enabled by default.

It is also possible to test whether there are more results by calling mysql_more_results(). However, this function does not change the connection state, so if it returns true, you must still call mysql_next_result() to advance to the next result.

For an example that shows how to use mysql_next_result(), see Section 28.6.22, “C API Multiple Statement Execution Support”.

Return Values
Return Value	Description
0	Successful and there are more results
-1	Successful and there are no more results
>0	An error occurred
"""=#
function nextresult(mysql::MYSQL)
    ret = mysql_next_result(mysql.ptr)
    return ret == -1 ? nothing : reg == 0 ? ret : throw(Error(mysql))
end

#="""
Description
Returns the number of columns in a result set.

You can get the number of columns either from a pointer to a result set or to a connection handler. You would use the connection handler if mysql_store_result() or mysql_use_result() returned NULL (and thus you have no result set pointer). In this case, you can call mysql_field_count() to determine whether mysql_store_result() should have produced a nonempty result. This enables the client program to take proper action without knowing whether the query was a SELECT (or SELECT-like) statement. The example shown here illustrates how this may be done.

See Section 28.6.28.1, “Why mysql_store_result() Sometimes Returns NULL After mysql_query() Returns Success”.

Return Values
An unsigned integer representing the number of columns in a result set.
"""=#
function numfields(result::MYSQL_RES)
    return mysql_num_fields(result.ptr)
end

#="""
Description
Returns the number of rows in the result set.

The use of mysql_num_rows() depends on whether you use mysql_store_result() or mysql_use_result() to return the result set. If you use mysql_store_result(), mysql_num_rows() may be called immediately. If you use mysql_use_result(), mysql_num_rows() does not return the correct value until all the rows in the result set have been retrieved.

mysql_num_rows() is intended for use with statements that return a result set, such as SELECT. For statements such as INSERT, UPDATE, or DELETE, the number of affected rows can be obtained with mysql_affected_rows().

Return Values
The number of rows in the result set.
"""=#
function numrows(result::MYSQL_RES)
    return mysql_num_rows(result.ptr)
end

#="""
Description
Can be used to set extra connect options and affect behavior for a connection. This function may be called multiple times to set several options. To retrieve option values, use mysql_get_option().

Call mysql_options() after mysql_init() and before mysql_connect() or mysql_real_connect().

The option argument is the option that you want to set; the arg argument is the value for the option. If the option is an integer, specify a pointer to the value of the integer as the arg argument.

Options for information such as SSL certificate and key files are used to establish an encrypted connection if such connections are available, but do not enforce any requirement that the connection obtained be encrypted. To require an encrypted connection, use the technique described in Section 28.6.21, “C API Encrypted Connection Support”.

The following list describes the possible options, their effect, and how arg is used for each option. For option descriptions that indicate arg is unused, its value is irrelevant; it is conventional to pass 0.

MYSQL_DEFAULT_AUTH (argument type: char *)

The name of the authentication plugin to use.

MYSQL_ENABLE_CLEARTEXT_PLUGIN (argument type: bool *)

Enable the mysql_clear_password cleartext authentication plugin. See Section 6.4.1.4, “Client-Side Cleartext Pluggable Authentication”.

MYSQL_INIT_COMMAND (argument type: char *)

SQL statement to execute when connecting to the MySQL server. Automatically re-executed if reconnection occurs.

MYSQL_OPT_BIND (argument: char *)

The network interface from which to connect to the server. This is used when the client host has multiple network interfaces. The argument is a host name or IP address (specified as a string).

MYSQL_OPT_CAN_HANDLE_EXPIRED_PASSWORDS (argument type: bool *)

Indicate whether the client can handle expired passwords. See Section 6.2.16, “Server Handling of Expired Passwords”.

MYSQL_OPT_COMPRESS (argument: not used)

Compress all information sent between the client and the server if possible. See Section 4.2.6, “Connection Compression Control”.

As of MySQL 8.0.18, MYSQL_OPT_COMPRESS becomes a legacy option, due to the introduction of the MYSQL_OPT_COMPRESSION_ALGORITHMS option for more control over connection compression (see Connection Compression Configuration). The meaning of MYSQL_OPT_COMPRESS depends on whether MYSQL_OPT_COMPRESSION_ALGORITHMS is specified:

When MYSQL_OPT_COMPRESSION_ALGORITHMS is not specified, enabling MYSQL_OPT_COMPRESS is equivalent to specifying a client-side algorithm set of zlib,uncompressed.

When MYSQL_OPT_COMPRESSION_ALGORITHMS is specified, enabling MYSQL_OPT_COMPRESS is equivalent to specifying an algorithm set of zlib and the full client-side algorithm set is the union of zlib plus the algorithms specified by MYSQL_OPT_COMPRESSION_ALGORITHMS. For example, with MYSQL_OPT_COMPRESS enabled and MYSQL_OPT_COMPRESSION_ALGORITHMS set to zlib,zstd, the permitted-algorithm set is zlib plus zlib,zstd; that is, zlib,zstd. With MYSQL_OPT_COMPRESS enabled and MYSQL_OPT_COMPRESSION_ALGORITHMS set to zstd,uncompressed, the permitted-algorithm set is zlib plus zstd,uncompressed; that is, zlib,zstd,uncompressed.

As of MySQL 8.0.18, MYSQL_OPT_COMPRESS is deprecated. It will be removed in a future MySQL version. See Legacy Connection Compression Configuration.

MYSQL_OPT_COMPRESSION_ALGORITHMS (argument type: const char *)

The permitted compression algorithms for connections to the server. The available algorithms are the same as for the protocol_compression_algorithms system variable. If this option is not specified, the default value is uncompressed.

For more information, see Section 4.2.6, “Connection Compression Control”.

This option was added in MySQL 8.0.18.

MYSQL_OPT_CONNECT_ATTR_DELETE (argument type: char *)

Given a key name, this option deletes a key-value pair from the current set of connection attributes to pass to the server at connect time. The argument is a pointer to a null-terminated string naming the key. Comparison of the key name with existing keys is case-sensitive.

See also the description for the MYSQL_OPT_CONNECT_ATTR_RESET option, as well as the description for the MYSQL_OPT_CONNECT_ATTR_ADD option in the description of the mysql_options4() function. That function description also includes a usage example.

The Performance Schema exposes connection attributes through the session_connect_attrs and session_account_connect_attrs tables. See Section 26.12.9, “Performance Schema Connection Attribute Tables”.

MYSQL_OPT_CONNECT_ATTR_RESET (argument not used)

This option resets (clears) the current set of connection attributes to pass to the server at connect time.

See also the description for the MYSQL_OPT_CONNECT_ATTR_DELETE option, as well as the description for the MYSQL_OPT_CONNECT_ATTR_ADD option in the description of the mysql_options4() function. That function description also includes a usage example.

The Performance Schema exposes connection attributes through the session_connect_attrs and session_account_connect_attrs tables. See Section 26.12.9, “Performance Schema Connection Attribute Tables”.

MYSQL_OPT_CONNECT_TIMEOUT (argument type: unsigned int *)

The connect timeout in seconds.

MYSQL_OPT_GET_SERVER_PUBLIC_KEY (argument type: bool *)

Enables the client to request from the server the public key required for RSA key pair-based password exchange. This option applies to clients that authenticate with the caching_sha2_password authentication plugin. For that plugin, the server does not send the public key unless requested. This option is ignored for accounts that do not authenticate with that plugin. It is also ignored if RSA-based password exchange is not used, as is the case when the client connects to the server using a secure connection.

If MYSQL_SERVER_PUBLIC_KEY is given and specifies a valid public key file, it takes precedence over MYSQL_OPT_GET_SERVER_PUBLIC_KEY.

For information about the caching_sha2_password plugin, see Section 6.4.1.2, “Caching SHA-2 Pluggable Authentication”.

MYSQL_OPT_LOCAL_INFILE (argument type: optional pointer to unsigned int)

This option affects client-side LOCAL capability for LOAD DATA operations. By default, LOCAL capability is determined by the default compiled into the MySQL client library (see Section 13.2.7, “LOAD DATA Statement”). To control this capability explicitly, invoke mysql_options() to set the MYSQL_OPT_LOCAL_INFILE option:

LOCAL is disabled if the pointer points to an unsigned int that has a zero value.

LOCAL is enabled if no pointer is given or if the pointer points to an unsigned int that has a nonzero value.

Successful use of a LOCAL load operation by a client also requires that the server permits it.

MYSQL_OPT_MAX_ALLOWED_PACKET (argument: unsigned long *)

This option sets the max_allowed_packet system variable. If the mysql argument is non-NULL, the call sets the session system variable value for that session. If mysql is NULL, the call sets the global system variable value.

MYSQL_OPT_NAMED_PIPE (argument: not used)

Use a named pipe to connect to the MySQL server on Windows, if the server permits named-pipe connections.

MYSQL_OPT_NET_BUFFER_LENGTH (argument: unsigned long *)

This option sets the net_buffer_length system variable. If the mysql argument is non-NULL, the call sets the session system variable value for that session. If mysql is NULL, the call sets the global system variable value.

MYSQL_OPT_OPTIONAL_RESULTSET_METADATA (argument type: bool *)

This flag makes result set metadata optional. It is an alternative way of setting the CLIENT_OPTIONAL_RESULTSET_METADATA connection flag for the mysql_real_connect() function. For details about managing result set metadata transfer, see Section 28.6.26, “C API Optional Result Set Metadata”.

MYSQL_OPT_PROTOCOL (argument type: unsigned int *)

Type of protocol to use. Specify one of the enum values of mysql_protocol_type defined in mysql.h.

MYSQL_OPT_READ_TIMEOUT (argument type: unsigned int *)

The timeout in seconds for each attempt to read from the server. There are retries if necessary, so the total effective timeout value is three times the option value. You can set the value so that a lost connection can be detected earlier than the TCP/IP Close_Wait_Timeout value of 10 minutes.

MYSQL_OPT_RECONNECT (argument type: bool *)

Enable or disable automatic reconnection to the server if the connection is found to have been lost. Reconnect is off by default; this option provides a way to set reconnection behavior explicitly. See Section 28.6.27, “C API Automatic Reconnection Control”.

MYSQL_OPT_RETRY_COUNT (argument type: unsigned int *)

The retry count for I/O-related system calls that are interrupted while connecting to the server or communicating with it. If this option is not specified, the default value is 1 (1 retry if the initial call is interrupted for 2 tries total).

This option can be used only by clients that link against a C client library compiled with NDB Cluster support.

MYSQL_OPT_SSL_CA (argument type: char *)

The path name of the Certificate Authority (CA) certificate file. This option, if used, must specify the same certificate used by the server.

MYSQL_OPT_SSL_CAPATH (argument type: char *)

The path name of the directory that contains trusted SSL CA certificate files.

MYSQL_OPT_SSL_CERT (argument type: char *)

The path name of the client public key certificate file.

MYSQL_OPT_SSL_CIPHER (argument type: char *)

The list of permissible ciphers for SSL encryption.

MYSQL_OPT_SSL_CRL (argument type: char *)

The path name of the file containing certificate revocation lists.

MYSQL_OPT_SSL_CRLPATH (argument type: char *)

The path name of the directory that contains files containing certificate revocation lists.

MYSQL_OPT_SSL_FIPS_MODE (argument type: unsigned int *)

Controls whether to enable FIPS mode on the client side. The MYSQL_OPT_SSL_FIPS_MODE option differs from other MYSQL_OPT_SSL_xxx options in that it is not used to establish encrypted connections, but rather to affect which cryptographic operations are permitted. See Section 6.5, “FIPS Support”.

Permitted option values are SSL_FIPS_MODE_OFF, SSL_FIPS_MODE_ON, and SSL_FIPS_MODE_STRICT.

Note
If the OpenSSL FIPS Object Module is not available, the only permitted value for MYSQL_OPT_SSL_FIPS_MODE is SSL_FIPS_MODE_OFF. In this case, setting MYSQL_OPT_SSL_FIPS_MODE to SSL_FIPS_MODE_ON or SSL_FIPS_MODE_STRICT causes the client to produce a warning at startup and to operate in non-FIPS mode.

MYSQL_OPT_SSL_KEY (argument type: char *)

The path name of the client private key file.

MYSQL_OPT_SSL_MODE (argument type: unsigned int *)

The security state to use for the connection to the server: SSL_MODE_DISABLED, SSL_MODE_PREFERRED, SSL_MODE_REQUIRED, SSL_MODE_VERIFY_CA, SSL_MODE_VERIFY_IDENTITY. If this option is not specified, the default is SSL_MODE_PREFERRED. These modes are the permitted values of the mysql_ssl_mode enumeration defined in mysql.h. For more information about the security states, see the description of --ssl-mode in Command Options for Encrypted Connections.

MYSQL_OPT_TLS_CIPHERSUITES (argument type: char *)

Which ciphersuites the client permits for encrypted connections that use TLSv1.3. The value is a list of one or more colon-separated ciphersuite names. The ciphersuites that can be named for this option depend on the SSL library used to compile MySQL. For details, see Section 6.3.2, “Encrypted Connection TLS Protocols and Ciphers”.

This option was added in MySQL 8.0.16.

MYSQL_OPT_TLS_VERSION (argument type: char *)

Which protocols the client permits for encrypted connections. The value is a list of one or more comma-separated protocol versions. The protocols that can be named for this option depend on the SSL library used to compile MySQL. For details, see Section 6.3.2, “Encrypted Connection TLS Protocols and Ciphers”.

MYSQL_OPT_USE_RESULT (argument: not used)

This option is unused.

MYSQL_OPT_WRITE_TIMEOUT (argument type: unsigned int *)

The timeout in seconds for each attempt to write to the server. There is a retry if necessary, so the total effective timeout value is two times the option value.

MYSQL_OPT_ZSTD_COMPRESSION_LEVEL (argument type: unsigned int *)

The compression level to use for connections to the server that use the zstd compression algorithm. The permitted levels are from 1 to 22, with larger values indicating increasing levels of compression. If this option is not specified, the default zstd compression level is 3. The compression level setting has no effect on connections that do not use zstd compression.

For more information, see Section 4.2.6, “Connection Compression Control”.

This option was added in MySQL 8.0.18.

MYSQL_PLUGIN_DIR (argument type: char *)

The directory in which to look for client plugins.

MYSQL_READ_DEFAULT_FILE (argument type: char *)

Read options from the named option file instead of from my.cnf.

MYSQL_READ_DEFAULT_GROUP (argument type: char *)

Read options from the named group from my.cnf or the file specified with MYSQL_READ_DEFAULT_FILE.

MYSQL_REPORT_DATA_TRUNCATION (argument type: bool *)

Enable or disable reporting of data truncation errors for prepared statements using the error member of MYSQL_BIND structures. (Default: enabled.)

MYSQL_SERVER_PUBLIC_KEY (argument type: char *)

The path name of the file containing a client-side copy of the public key required by the server for RSA key pair-based password exchange. The file must be in PEM format. This option applies to clients that authenticate with the sha256_password or caching_sha2_password authentication plugin. This option is ignored for accounts that do not authenticate with one of those plugins. It is also ignored if RSA-based password exchange is not used, as is the case when the client connects to the server using a secure connection.

If MYSQL_SERVER_PUBLIC_KEY is given and specifies a valid public key file, it takes precedence over MYSQL_OPT_GET_SERVER_PUBLIC_KEY.

For information about the sha256_password and caching_sha2_password plugins, see Section 6.4.1.3, “SHA-256 Pluggable Authentication”, and Section 6.4.1.2, “Caching SHA-2 Pluggable Authentication”.

MYSQL_SET_CHARSET_DIR (argument type: char *)

The path name of the directory that contains character set definition files.

MYSQL_SET_CHARSET_NAME (argument type: char *)

The name of the character set to use as the default character set. The argument can be MYSQL_AUTODETECT_CHARSET_NAME to cause the character set to be autodetected based on the operating system setting (see Section 10.4, “Connection Character Sets and Collations”).

MYSQL_SHARED_MEMORY_BASE_NAME (argument type: char *)

The name of the shared-memory object for communication to the server on Windows, if the server supports shared-memory connections. Specify the same value as used for the shared_memory_base_name system variable. of the mysqld server you want to connect to.

The client group is always read if you use MYSQL_READ_DEFAULT_FILE or MYSQL_READ_DEFAULT_GROUP.

The specified group in the option file may contain the following options.

Option	Description
character-sets-dir=dir_name	The directory where character sets are installed.
compress	Use the compressed client/server protocol.
connect-timeout=seconds	The connect timeout in seconds. On Linux this timeout is also used for waiting for the first answer from the server.
database=db_name	Connect to this database if no database was specified in the connect command.
debug	Debug options.
default-character-set=charset_name	The default character set to use.
disable-local-infile	Disable use of LOAD DATA LOCAL.
enable-cleartext-plugin	Enable the mysql_clear_password cleartext authentication plugin.
host=host_name	Default host name.
init-command=stmt	Statement to execute when connecting to MySQL server. Automatically re-executed if reconnection occurs.
interactive-timeout=seconds	Same as specifying CLIENT_INTERACTIVE to mysql_real_connect(). See Section 28.6.6.54, “mysql_real_connect()”.
local-infile[={0|1}]	If no argument or nonzero argument, enable use of LOAD DATA LOCAL; otherwise disable.
max_allowed_packet=bytes	Maximum size of packet that client can read from server.
multi-queries, multi-results	Enable multiple result sets from multiple-statement executions or stored procedures.
multi-statements	Enable the client to send multiple statements in a single string (separated by ; characters).
password=password	Default password.
pipe	Use named pipes to connect to a MySQL server on Windows.
port=port_num	Default port number.
protocol={TCP|SOCKET|PIPE|MEMORY}	The protocol to use when connecting to the server.
return-found-rows	Tell mysql_info() to return found rows instead of updated rows when using UPDATE.
shared-memory-base-name=name	Shared-memory name to use to connect to server.
socket={file_name|pipe_name}	Default socket file.
ssl-ca=file_name	Certificate Authority file.
ssl-capath=dir_name	Certificate Authority directory.
ssl-cert=file_name	Certificate file.
ssl-cipher=cipher_list	Permissible SSL ciphers.
ssl-key=file_name	Key file.
timeout=seconds	Like connect-timeout.
user	Default user.
Option	Description
timeout has been replaced by connect-timeout, but timeout is still supported for backward compatibility.

For more information about option files used by MySQL programs, see Section 4.2.2.2, “Using Option Files”.
"""=#
function setoption(mysql::MYSQL, option::mysql_option, arg="0")
    if option in CUINTOPTS
        ref = Ref{Cuint}(arg)
    elseif option in CULONGOPTS
        ref = Ref{Culong}(arg)
    elseif option in BOOLOPTS
        ref = Ref{Bool}(arg)
    else
        ref = convert(Ptr{Cvoid}, pointer(arg))
    end
    return @checksuccess mysql mysql_options(mysql.ptr, option, ref)
end

#="""
Description
mysql_options4() is similar to mysql_options() but has an extra fourth argument so that two values can be passed for the option specified in the second argument.

The following list describes the permitted options, their effect, and how arg1 and arg2 are used.

MYSQL_OPT_CONNECT_ATTR_ADD (argument types: char *, char *)

This option adds an attribute key-value pair to the current set of connection attributes to pass to the server at connect time. Both arguments are pointers to null-terminated strings. The first and second strings indicate the key and value, respectively. If the key is empty or already exists in the current set of connection attributes, an error occurs. Comparison of the key name with existing keys is case-sensitive.

Key names that begin with an underscore (_) are reserved for internal use and should not be created by application programs. This convention permits new attributes to be introduced by MySQL without colliding with application attributes.

mysql_options4() imposes a limit of 64KB on the aggregate size of connection attribute data it will accept. For calls that cause this limit to be exceeded, a CR_INVALID_PARAMETER_NO error occurs. Attribute size-limit checks also occur on the server side. For details, see Section 26.12.9, “Performance Schema Connection Attribute Tables”, which also describes how the Performance Schema exposes connection attributes through the session_connect_attrs and session_account_connect_attrs tables.

See also the descriptions for the MYSQL_OPT_CONNECT_ATTR_RESET and MYSQL_OPT_CONNECT_ATTR_DELETE options in the description of the mysql_options() function.
"""=#
function setoption(mysql::MYSQL, option::mysql_option, arg1, arg2)
    ref1 = Ref{String}(arg1)
    ref2 = Ref{String}(arg2)
    return @checksuccess mysql mysql_options4(mysql.ptr, option, ref1, ref2)
end

#="""
Description
Checks whether the connection to the server is working. If the connection has gone down and auto-reconnect is enabled an attempt to reconnect is made. If the connection is down and auto-reconnect is disabled, mysql_ping() returns an error.

Auto-reconnect is disabled by default. To enable it, call mysql_options() with the MYSQL_OPT_RECONNECT option. For details, see Section 28.6.6.50, “mysql_options()”.

mysql_ping() can be used by clients that remain idle for a long while, to check whether the server has closed the connection and reconnect if necessary.

If mysql_ping()) does cause a reconnect, there is no explicit indication of it. To determine whether a reconnect occurs, call mysql_thread_id() to get the original connection identifier before calling mysql_ping(), then call mysql_thread_id() again to see whether the identifier has changed.

If reconnect occurs, some characteristics of the connection will have been reset. For details about these characteristics, see Section 28.6.27, “C API Automatic Reconnection Control”.

Return Values
Zero if the connection to the server is active. Nonzero if an error occurred. A nonzero return does not indicate whether the MySQL server itself is down; the connection might be broken for other reasons such as network problems.
"""=#
function ping(mysql::MYSQL)
    return @checksuccess mysql mysql_ping(mysql.ptr)
end

#="""
Description
Passes an option type and value to a plugin. This function can be called multiple times to set several options. If the plugin does not have an option handler, an error occurs.

Specify the parameters as follows:

plugin: A pointer to the plugin structure.

option: The option to be set.

value: A pointer to the option value.

Return Values
Zero for success, 1 if an error occurred. If the plugin has an option handler, that handler should also return zero for success and 1 if an error occurred.
"""=#
function pluginoption(plugin::Ptr{Cvoid}, option::String, value)
    mysql_plugin_options(plugin, option, value)
end

#="""
mysql_real_connect() attempts to establish a connection to a MySQL database engine running on host. mysql_real_connect() must complete successfully before you can execute any other API functions that require a valid MYSQL connection handler structure.

The parameters are specified as follows:

For the first parameter, specify the address of an existing MYSQL structure. Before calling mysql_real_connect(), call mysql_init() to initialize the MYSQL structure. You can change a lot of connect options with the mysql_options() call. See Section 28.6.6.50, “mysql_options()”.

The value of host may be either a host name or an IP address. The client attempts to connect as follows:

If host is NULL or the string "localhost", a connection to the local host is assumed:

On Windows, the client connects using a shared-memory connection, if the server has shared-memory connections enabled.

On Unix, the client connects using a Unix socket file. The unix_socket parameter or the MYSQL_UNIX_PORT environment variable may be used to specify the socket name.

On Windows, if host is ".", or TCP/IP is not enabled and no unix_socket is specified or the host is empty, the client connects using a named pipe, if the server has named-pipe connections enabled. If named-pipe connections are not enabled, an error occurs.

Otherwise, TCP/IP is used.

You can also influence the type of connection to use with the MYSQL_OPT_PROTOCOL or MYSQL_OPT_NAMED_PIPE options to mysql_options(). The type of connection must be supported by the server.

The user parameter contains the user's MySQL login ID. If user is NULL or the empty string "", the current user is assumed. Under Unix, this is the current login name. Under Windows ODBC, the current user name must be specified explicitly. See the Connector/ODBC section of Chapter 28, Connectors and APIs.

The passwd parameter contains the password for user. If passwd is NULL, only entries in the user table for the user that have a blank (empty) password field are checked for a match. This enables the database administrator to set up the MySQL privilege system in such a way that users get different privileges depending on whether they have specified a password.

Note
Do not attempt to encrypt the password before calling mysql_real_connect(); password encryption is handled automatically by the client API.

The user and passwd parameters use whatever character set has been configured for the MYSQL object. By default, this is utf8mb4, but can be changed by calling mysql_options(mysql, MYSQL_SET_CHARSET_NAME, "charset_name") prior to connecting.

db is the database name. If db is not NULL, the connection sets the default database to this value.

If port is not 0, the value is used as the port number for the TCP/IP connection. Note that the host parameter determines the type of the connection.

If unix_socket is not NULL, the string specifies the socket or named pipe to use. Note that the host parameter determines the type of the connection.

The value of client_flag is usually 0, but can be set to a combination of the following flags to enable certain features:

CAN_HANDLE_EXPIRED_PASSWORDS: The client can handle expired passwords. For more information, see Section 6.2.16, “Server Handling of Expired Passwords”.

CLIENT_COMPRESS: Use compression in the client/server protocol.

CLIENT_FOUND_ROWS: Return the number of found (matched) rows, not the number of changed rows.

CLIENT_IGNORE_SIGPIPE: Prevents the client library from installing a SIGPIPE signal handler. This can be used to avoid conflicts with a handler that the application has already installed.

CLIENT_IGNORE_SPACE: Permit spaces after function names. Makes all functions names reserved words.

CLIENT_INTERACTIVE: Permit interactive_timeout seconds of inactivity (rather than wait_timeout seconds) before closing the connection. The client's session wait_timeout variable is set to the value of the session interactive_timeout variable.

CLIENT_LOCAL_FILES: Enable LOAD DATA LOCAL handling.

CLIENT_MULTI_RESULTS: Tell the server that the client can handle multiple result sets from multiple-statement executions or stored procedures. This flag is automatically enabled if CLIENT_MULTI_STATEMENTS is enabled. See the note following this table for more information about this flag.

CLIENT_MULTI_STATEMENTS: Tell the server that the client may send multiple statements in a single string (separated by ; characters). If this flag is not set, multiple-statement execution is disabled. See the note following this table for more information about this flag.

CLIENT_NO_SCHEMA Do not permit db_name.tbl_name.col_name syntax. This is for ODBC. It causes the parser to generate an error if you use that syntax, which is useful for trapping bugs in some ODBC programs.

CLIENT_ODBC: Unused.

CLIENT_OPTIONAL_RESULTSET_METADATA: This flag makes result set metadata optional. Suppression of metadata transfer can improve performance, particularly for sessions that execute many queries that return few rows each. For details about managing result set metadata transfer, see Section 28.6.26, “C API Optional Result Set Metadata”.

CLIENT_SSL: Use SSL (encrypted protocol). Do not set this option within an application program; it is set internally in the client library. Instead, use mysql_options() or mysql_ssl_set() before calling mysql_real_connect().

CLIENT_REMEMBER_OPTIONS Remember options specified by calls to mysql_options(). Without this option, if mysql_real_connect() fails, you must repeat the mysql_options() calls before trying to connect again. With this option, the mysql_options() calls need not be repeated.

If your program uses CALL statements to execute stored procedures, the CLIENT_MULTI_RESULTS flag must be enabled. This is because each CALL returns a result to indicate the call status, in addition to any result sets that might be returned by statements executed within the procedure. Because CALL can return multiple results, process them using a loop that calls mysql_next_result() to determine whether there are more results.

CLIENT_MULTI_RESULTS can be enabled when you call mysql_real_connect(), either explicitly by passing the CLIENT_MULTI_RESULTS flag itself, or implicitly by passing CLIENT_MULTI_STATEMENTS (which also enables CLIENT_MULTI_RESULTS). CLIENT_MULTI_RESULTS is enabled by default.

If you enable CLIENT_MULTI_STATEMENTS or CLIENT_MULTI_RESULTS, process the result for every call to mysql_query() or mysql_real_query() by using a loop that calls mysql_next_result() to determine whether there are more results. For an example, see Section 28.6.22, “C API Multiple Statement Execution Support”.

For some parameters, it is possible to have the value taken from an option file rather than from an explicit value in the mysql_real_connect() call. To do this, call mysql_options() with the MYSQL_READ_DEFAULT_FILE or MYSQL_READ_DEFAULT_GROUP option before calling mysql_real_connect(). Then, in the mysql_real_connect() call, specify the “no-value” value for each parameter to be read from an option file:

For host, specify a value of NULL or the empty string ("").

For user, specify a value of NULL or the empty string.

For passwd, specify a value of NULL. (For the password, a value of the empty string in the mysql_real_connect() call cannot be overridden in an option file, because the empty string indicates explicitly that the MySQL account must have an empty password.)

For db, specify a value of NULL or the empty string.

For port, specify a value of 0.

For unix_socket, specify a value of NULL.

If no value is found in an option file for a parameter, its default value is used as indicated in the descriptions given earlier in this section.

Return Values
A MYSQL* connection handler if the connection was successful, NULL if the connection was unsuccessful. For a successful connection, the return value is the same as the value of the first parameter.
"""=#
function connect(mysql::MYSQL, host::String, user::String, passwd::String, db::String, port::Integer, unix_socket::String, client_flag)
    @checknull mysql mysql_real_connect(mysql.ptr, host, user, passwd, db, port, unix_socket, client_flag)
    return mysql
end

#="""
The mysql argument must be a valid, open connection because character escaping depends on the character set in use by the server.

The string in the from argument is encoded to produce an escaped SQL string, taking into account the current character set of the connection. The result is placed in the to argument, followed by a terminating null byte.

Characters encoded are \\, ', ", NUL (ASCII 0), \\n, \\r, and Control+Z. Strictly speaking, MySQL requires only that backslash and the quote character used to quote the string in the query be escaped. mysql_real_escape_string() quotes the other characters to make them easier to read in log files. For comparison, see the quoting rules for literal strings and the QUOTE() SQL function in Section 9.1.1, “String Literals”, and Section 12.7, “String Functions and Operators”.

The string pointed to by from must be length bytes long. You must allocate the to buffer to be at least length*2+1 bytes long. (In the worst case, each character may need to be encoded as using two bytes, and there must be room for the terminating null byte.) When mysql_real_escape_string() returns, the contents of to is a null-terminated string. The return value is the length of the encoded string, not including the terminating null byte.

If you must change the character set of the connection, use the mysql_set_character_set() function rather than executing a SET NAMES (or SET CHARACTER SET) statement. mysql_set_character_set() works like SET NAMES but also affects the character set used by mysql_real_escape_string(), which SET NAMES does not.
"""=#
function escapestring(mysql::MYSQL, str::String)
    len = sizeof(str)
    to = Base.StringVector(len * 2 + 1)
    tolen = mysql_real_escape_string(mysql.ptr, to, str, len)
    resize!(to, tolen)
    return String(to)
end

#="""
This function creates a legal SQL string for use in an SQL statement. See Section 9.1.1, “String Literals”.

The mysql argument must be a valid, open connection because character escaping depends on the character set in use by the server.

The string in the from argument is encoded to produce an escaped SQL string, taking into account the current character set of the connection. The result is placed in the to argument, followed by a terminating null byte.

Characters encoded are \\, ', ", NUL (ASCII 0), \\n, \\r, Control+Z, and `. Strictly speaking, MySQL requires only that backslash and the quote character used to quote the string in the query be escaped. mysql_real_escape_string_quote() quotes the other characters to make them easier to read in log files. For comparison, see the quoting rules for literal strings and the QUOTE() SQL function in Section 9.1.1, “String Literals”, and Section 12.7, “String Functions and Operators”.

Note
If the ANSI_QUOTES SQL mode is enabled, mysql_real_escape_string_quote() cannot be used to escape double quote characters for use within double-quoted identifiers. (The function cannot tell whether the mode is enabled to determine the proper escaping character.)

The string pointed to by from must be length bytes long. You must allocate the to buffer to be at least length*2+1 bytes long. (In the worst case, each character may need to be encoded as using two bytes, and there must be room for the terminating null byte.) When mysql_real_escape_string_quote() returns, the contents of to is a null-terminated string. The return value is the length of the encoded string, not including the terminating null byte.

The quote argument indicates the context in which the escaped string is to be placed. Suppose that you intend to escape the from argument and insert the escaped string (designated here by str) into one of the following statements:

1) SELECT * FROM table WHERE name = 'str'
2) SELECT * FROM table WHERE name = "str"
3) SELECT * FROM `str` WHERE id = 103
To perform escaping properly for each statement, call mysql_real_escape_string_quote() as follows, where the final argument indicates the quoting context:

1) len = mysql_real_escape_string_quote(&mysql,to,from,from_len,'\\'');
2) len = mysql_real_escape_string_quote(&mysql,to,from,from_len,'"');
3) len = mysql_real_escape_string_quote(&mysql,to,from,from_len,'`');
If you must change the character set of the connection, use the mysql_set_character_set() function rather than executing a SET NAMES (or SET CHARACTER SET) statement. mysql_set_character_set() works like SET NAMES but also affects the character set used by mysql_real_escape_string_quote(), which SET NAMES does not.

Example
The following example inserts two escaped strings into an INSERT statement, each within single quote characters:

char query[1000],*end;

end = my_stpcpy(query,"INSERT INTO test_table VALUES('");
end += mysql_real_escape_string_quote(&mysql,end,"What is this",12,'\\'');
end = my_stpcpy(end,"','");
end += mysql_real_escape_string_quote(&mysql,end,"binary data: \\0\\r\\n",16,'\'');
end = my_stpcpy(end,"')");

if (mysql_real_query(&mysql,query,(unsigned int) (end - query)))
{
   fprintf(stderr, "Failed to insert row, Error: %s\\n",
           mysql_error(&mysql));
}
The my_stpcpy() function used in the example is included in the libmysqlclient library and works like strcpy() but returns a pointer to the terminating null of the first parameter.
"""=#
function escapestringquote(mysql::MYSQL, str::String, q::Char)
    len = sizeof(str)
    to = Base.StringVector(len * 2 + 1)
    tolen = mysql_real_escape_string_quote(mysql.ptr, to, str, len, q)
    resize!(to, tolen)
    return String(to)
end

#="""
mysql_real_query() executes the SQL statement pointed to by stmt_str, a string length bytes long. Normally, the string must consist of a single SQL statement without a terminating semicolon (;) or \\g. If multiple-statement execution has been enabled, the string can contain several statements separated by semicolons. See Section 28.6.22, “C API Multiple Statement Execution Support”.

mysql_query() cannot be used for statements that contain binary data; you must use mysql_real_query() instead. (Binary data may contain the \\0 character, which mysql_query() interprets as the end of the statement string.) In addition, mysql_real_query() is faster than mysql_query() because it does not call strlen() on the statement string.

If you want to know whether the statement returns a result set, you can use mysql_field_count() to check for this. See Section 28.6.6.22, “mysql_field_count()”.

Return Values
Zero for success. Nonzero if an error occurred.
"""=#
function query(mysql::MYSQL, sql::String)
    return @checksuccess mysql mysql_real_query(mysql.ptr, sql, sizeof(sql))
end

#="""
Resets the connection to clear the session state.

mysql_reset_connection() has effects similar to mysql_change_user() or an auto-reconnect except that the connection is not closed and reopened, and reauthentication is not done. The write set session history is reset. See Section 28.6.6.3, “mysql_change_user()”, and Section 28.6.27, “C API Automatic Reconnection Control”.

The connection-related state is affected as follows:

Any active transactions are rolled back and autocommit mode is reset.

All table locks are released.

All TEMPORARY tables are closed (and dropped).

Session system variables are reinitialized to the values of the corresponding global system variables, including system variables that are set implicitly by statements such as SET NAMES.

User variable settings are lost.

Prepared statements are released.

HANDLER variables are closed.

The value of LAST_INSERT_ID() is reset to 0.

Locks acquired with GET_LOCK() are released.
"""=#
function resetconnection(mysql::MYSQL)
    return @checksuccess mysql mysql_reset_connection(mysql.ptr)
end

#="""
Clears from the client library any cached copy of the public key required by the server for RSA key pair-based password exchange. This might be necessary when the server has been restarted with a different RSA key pair after the client program had called mysql_options() with the MYSQL_SERVER_PUBLIC_KEY option to specify the RSA public key. In such cases, connection failure can occur due to key mismatch. To fix this problem, the client can use either of the following approaches:

The client can call mysql_reset_server_public_key() to clear the cached key and try again, after the public key file on the client side has been replaced with a file containing the new public key.

The client can call mysql_reset_server_public_key() to clear the cached key, then call mysql_options() with the MYSQL_OPT_GET_SERVER_PUBLIC_KEY option (instead of MYSQL_SERVER_PUBLIC_KEY) to request the required public key from the server Do not use both MYSQL_OPT_GET_SERVER_PUBLIC_KEY and MYSQL_SERVER_PUBLIC_KEY because in that case, MYSQL_SERVER_PUBLIC_KEY takes precedence.
"""=#
function resetserverpublickey()
    mysql_reset_server_public_key()
end

#="""
Description
mysql_result_metadata() returns a value that indicates whether a result set has metadata. It can be useful for metadata-optional connections when the client does not know in advance whether particular result sets have metadata. For example, if a client executes a stored procedure that returns multiple result sets and might change the resultset_metadata system variable, the client can invoke mysql_result_metadata() for each result set to determine whether it has metadata.

For details about managing result set metadata transfer, see Section 28.6.26, “C API Optional Result Set Metadata”.

Return Values
mysql_result_metadata() returns one of these values:

enum enum_resultset_metadata {
 RESULTSET_METADATA_NONE= 0,
 RESULTSET_METADATA_FULL= 1
};

"""=#
function resultmetadata(result::MYSQL_RES)
    return mysql_result_metadata(result.ptr)
end

#="""
Description
Rolls back the current transaction.

The action of this function is subject to the value of the completion_type system variable. In particular, if the value of completion_type is RELEASE (or 2), the server performs a release after terminating a transaction and closes the client connection. Call mysql_close() from the client program to close the connection from the client side.
"""=#
function rollback(mysql::MYSQL)
    return @checksuccess mysql mysql_rollback(mysql.ptr)
end

#="""
Description
Sets the row cursor to an arbitrary row in a query result set. The offset value is a row offset, typically a value returned from mysql_row_tell() or from mysql_row_seek(). This value is not a row number; to seek to a row within a result set by number, use mysql_data_seek() instead.

This function requires that the result set structure contains the entire result of the query, so mysql_row_seek() may be used only in conjunction with mysql_store_result(), not with mysql_use_result().

Return Values
The previous value of the row cursor. This value may be passed to a subsequent call to mysql_row_seek().
"""=#
function rowseek(result::MYSQL_RES, offset::Ptr{Cvoid})
    return mysql_row_seek(result.ptr, offset)
end

#="""
Description
Returns the current position of the row cursor for the last mysql_fetch_row(). This value can be used as an argument to mysql_row_seek().

Use mysql_row_tell() only after mysql_store_result(), not after mysql_use_result().

Return Values
The current offset of the row cursor.
"""=#
function rowtell(result::MYSQL_RES)
    return mysql_row_tell(result.ptr)
end

#="""
Description
Causes the database specified by db to become the default (current) database on the connection specified by mysql. In subsequent queries, this database is the default for table references that include no explicit database specifier.

mysql_select_db() fails unless the connected user can be authenticated as having permission to use the database or some object within it.
"""=#
function selectdb(mysql::MYSQL, db::String)
    return @checksuccess mysql mysql_select_db(mysql.ptr, db)
end

#="""
This function is used to set the default character set for the current connection. The string csname specifies a valid character set name. The connection collation becomes the default collation of the character set. This function works like the SET NAMES statement, but also sets the value of mysql->charset, and thus affects the character set used by mysql_real_escape_string()
"""=#
function setcharacterset(mysql::MYSQL, csname::String)
    return @checksuccess mysql mysql_set_character_set(mysql.ptr, csname)
end

#="""
Sets the LOAD DATA LOCAL callback functions to the defaults used internally by the C client library. The library calls this function automatically if mysql_set_local_infile_handler() has not been called or does not supply valid functions for each of its callbacks.
"""=#
function setlocalinfiledefault(mysql::MYSQL)
    return mysql_set_local_infile_default(mysql.ptr)
end

#="""
Description
This function installs callbacks to be used during the execution of LOAD DATA LOCAL statements. It enables application programs to exert control over local (client-side) data file reading. The arguments are the connection handler, a set of pointers to callback functions, and a pointer to a data area that the callbacks can use to share information.

To use mysql_set_local_infile_handler(), you must write the following callback functions:

int
local_infile_init(void **ptr, const char *filename, void *userdata);
The initialization function. This is called once to do any setup necessary, open the data file, allocate data structures, and so forth. The first void** argument is a pointer to a pointer. You can set the pointer (that is, *ptr) to a value that will be passed to each of the other callbacks (as a void*). The callbacks can use this pointed-to value to maintain state information. The userdata argument is the same value that is passed to mysql_set_local_infile_handler().

Make the initialization function return zero for success, nonzero for an error.

int
local_infile_read(void *ptr, char *buf, unsigned int buf_len);
The data-reading function. This is called repeatedly to read the data file. buf points to the buffer where the read data is stored, and buf_len is the maximum number of bytes that the callback can read and store in the buffer. (It can read fewer bytes, but should not read more.)

The return value is the number of bytes read, or zero when no more data could be read (this indicates EOF). Return a value less than zero if an error occurs.

void
local_infile_end(void *ptr)
The termination function. This is called once after local_infile_read() has returned zero (EOF) or an error. Within this function, deallocate any memory allocated by local_infile_init() and perform any other cleanup necessary. It is invoked even if the initialization function returns an error.

int
local_infile_error(void *ptr,
                   char *error_msg,
                   unsigned int error_msg_len);
The error-handling function. This is called to get a textual error message to return to the user in case any of your other functions returns an error. error_msg points to the buffer into which the message is written, and error_msg_len is the length of the buffer. Write the message as a null-terminated string, at most error_msg_len−1 bytes long.

The return value is the error number.

Typically, the other callbacks store the error message in the data structure pointed to by ptr, so that local_infile_error() can copy the message from there into error_msg.

After calling mysql_set_local_infile_handler() in your C code and passing pointers to your callback functions, you can then issue a LOAD DATA LOCAL statement (for example, by using mysql_query()). The client library automatically invokes your callbacks. The file name specified in LOAD DATA LOCAL will be passed as the second parameter to the local_infile_init() callback.
"""=#
function setlocalinfilehandler(mysql::MYSQL, init::Ptr{Cvoid}, read::Ptr{Cvoid}, endf::Ptr{Cvoid}, error::Ptr{Cvoid}, userdata::Ptr{Cvoid})
    return mysql_set_local_infile_handler(mysql.ptr, init, read, endf, error, userdata)
end

#="""
Description
Enables or disables an option for the connection. option can have one of the following values.

Option	Description
MYSQL_OPTION_MULTI_STATEMENTS_ON	Enable multiple-statement support
MYSQL_OPTION_MULTI_STATEMENTS_OFF	Disable multiple-statement support
If you enable multiple-statement support, you should retrieve results from calls to mysql_query() or mysql_real_query() by using a loop that calls mysql_next_result() to determine whether there are more results. For an example, see Section 28.6.22, “C API Multiple Statement Execution Support”.

Enabling multiple-statement support with MYSQL_OPTION_MULTI_STATEMENTS_ON does not have quite the same effect as enabling it by passing the CLIENT_MULTI_STATEMENTS flag to mysql_real_connect(): CLIENT_MULTI_STATEMENTS also enables CLIENT_MULTI_RESULTS. If you are using the CALL SQL statement in your programs, multiple-result support must be enabled; this means that MYSQL_OPTION_MULTI_STATEMENTS_ON by itself is insufficient to permit the use of CALL.
"""=#
function setserveroption(mysql::MYSQL, option::mysql_option)
    return @checksuccess mysql mysql_set_server_option(mysql.ptr, option)
end

#="""
Returns a null-terminated string containing the SQLSTATE error code for the most recently executed SQL statement. The error code consists of five characters. '00000' means “no error.” The values are specified by ANSI SQL and ODBC. For a list of possible values, see Appendix B, Errors, Error Codes, and Common Problems.

SQLSTATE values returned by mysql_sqlstate() differ from MySQL-specific error numbers returned by mysql_errno(). For example, the mysql client program displays errors using the following format, where 1146 is the mysql_errno() value and '42S02' is the corresponding mysql_sqlstate() value:

shell> SELECT * FROM no_such_table;
ERROR 1146 (42S02): Table 'test.no_such_table' doesn't exist
Not all MySQL error numbers are mapped to SQLSTATE error codes. The value 'HY000' (general error) is used for unmapped error numbers.

If you call mysql_sqlstate() after mysql_real_connect() fails, mysql_sqlstate() might not return a useful value. For example, this happens if a host is blocked by the server and the connection is closed without any SQLSTATE value being sent to the client.
"""=#
function sqlstate(mysql::MYSQL)
    return unsafe_string(mysql_sqlstate(mysql.ptr))
end

#="""
Description
mysql_ssl_set() is used for establishing encrypted connections using SSL. The mysql argument must be a valid connection handler. Any unused SSL arguments may be given as NULL.

If used, mysql_ssl_set() must be called before mysql_real_connect(). mysql_ssl_set() does nothing unless SSL support is enabled in the client library.

It is optional to call mysql_ssl_set() to obtain an encrypted connection because by default, MySQL programs attempt to connect using encryption if the server supports encrypted connections, falling back to an unencrypted connection if an encrypted connection cannot be established (see Section 6.3.1, “Configuring MySQL to Use Encrypted Connections”). mysql_ssl_set() may be useful to applications that must specify particular certificate and key files, encryption ciphers, and so forth.

mysql_ssl_set() specifies SSL information such as certificate and key files for establishing an encrypted connection if such connections are available, but does not enforce any requirement that the connection obtained be encrypted. To require an encrypted connection, use the technique described in Section 28.6.21, “C API Encrypted Connection Support”.

For additional security relative to that provided by the default encryption, clients can supply a CA certificate matching the one used by the server and enable host name identity verification. In this way, the server and client place their trust in the same CA certificate and the client verifies that the host to which it connected is the one intended. For details, see Section 28.6.21, “C API Encrypted Connection Support”.

mysql_ssl_set() is a convenience function that is essentially equivalent to this set of mysql_options() calls:

mysql_options(mysql, MYSQL_OPT_SSL_KEY,    key);
mysql_options(mysql, MYSQL_OPT_SSL_CERT,   cert);
mysql_options(mysql, MYSQL_OPT_SSL_CA,     ca);
mysql_options(mysql, MYSQL_OPT_SSL_CAPATH, capath);
mysql_options(mysql, MYSQL_OPT_SSL_CIPHER, cipher);
Because of that equivalence, applications can, instead of calling mysql_ssl_set(), call mysql_options() directly, omitting calls for those options for which the option value is NULL. Moreover, mysql_options() offers encrypted-connection options not available using mysql_ssl_set(), such as MYSQL_OPT_SSL_MODE to specify the security state of the connection, and MYSQL_OPT_TLS_VERSION to specify the protocols the client permits for encrypted connections.

Arguments:

mysql: The connection handler returned from mysql_init().

key: The path name of the client private key file.

cert: The path name of the client public key certificate file.

ca: The path name of the Certificate Authority (CA) certificate file. This option, if used, must specify the same certificate used by the server.

capath: The path name of the directory that contains trusted SSL CA certificate files.

cipher: The list of permissible ciphers for SSL encryption.

Return Values
This function always returns 0. If SSL setup is incorrect, a subsequent mysql_real_connect() call returns an error when you attempt to connect.
"""=#
function sslset(mysql::MYSQL, key::String, cert::String, ca::String, capath::String, cipher::String)
    return mysql_ssl_set(mysql.ptr, key, cert, ca, capath, cipher)
end

#="""
Description
Returns a character string containing information similar to that provided by the mysqladmin status command. This includes uptime in seconds and the number of running threads, questions, reloads, and open tables.

Return Values
A character string describing the server status. NULL if an error occurred.
"""=#
function stat(mysql::MYSQL)
    return unsafe_string(@checknull mysql mysql_stat(mysql.ptr))
end

#="""
After invoking mysql_query() or mysql_real_query(), you must call mysql_store_result() or mysql_use_result() for every statement that successfully produces a result set (SELECT, SHOW, DESCRIBE, EXPLAIN, CHECK TABLE, and so forth). You must also call mysql_free_result() after you are done with the result set.

You need not call mysql_store_result() or mysql_use_result() for other statements, but it does not do any harm or cause any notable performance degradation if you call mysql_store_result() in all cases. You can detect whether the statement has a result set by checking whether mysql_store_result() returns a nonzero value (more about this later).

If you enable multiple-statement support, you should retrieve results from calls to mysql_query() or mysql_real_query() by using a loop that calls mysql_next_result() to determine whether there are more results. For an example, see Section 28.6.22, “C API Multiple Statement Execution Support”.

If you want to know whether a statement should return a result set, you can use mysql_field_count() to check for this. See Section 28.6.6.22, “mysql_field_count()”.

mysql_store_result() reads the entire result of a query to the client, allocates a MYSQL_RES structure, and places the result into this structure.

mysql_store_result() returns NULL if the statement did not return a result set (for example, if it was an INSERT statement), or an error occurred and reading of the result set failed.

An empty result set is returned if there are no rows returned. (An empty result set differs from a null pointer as a return value.)

After you have called mysql_store_result() and gotten back a result that is not a null pointer, you can call mysql_num_rows() to find out how many rows are in the result set.

You can call mysql_fetch_row() to fetch rows from the result set, or mysql_row_seek() and mysql_row_tell() to obtain or set the current row position within the result set.

See Section 28.6.28.1, “Why mysql_store_result() Sometimes Returns NULL After mysql_query() Returns Success”.

Return Values
A pointer to a MYSQL_RES result structure with the results. NULL if the statement did not return a result set or an error occurred. To determine whether an error occurred, check whether mysql_error() returns a nonempty string, mysql_errno() returns nonzero, or mysql_field_count() returns zero.
"""=#
function storeresult(mysql::MYSQL)
    return MYSQL_RES(mysql_store_result(mysql.ptr))
end

"""
This function indicates whether the client library is compiled as thread-safe.
"""
function threadsafe()
    return Bool(mysql_thread_safe())
end

#="""
Description
After invoking mysql_query() or mysql_real_query(), you must call mysql_store_result() or mysql_use_result() for every statement that successfully produces a result set (SELECT, SHOW, DESCRIBE, EXPLAIN, CHECK TABLE, and so forth). You must also call mysql_free_result() after you are done with the result set.

mysql_use_result() initiates a result set retrieval but does not actually read the result set into the client like mysql_store_result() does. Instead, each row must be retrieved individually by making calls to mysql_fetch_row(). This reads the result of a query directly from the server without storing it in a temporary table or local buffer, which is somewhat faster and uses much less memory than mysql_store_result(). The client allocates memory only for the current row and a communication buffer that may grow up to max_allowed_packet bytes.

On the other hand, you should not use mysql_use_result() for locking reads if you are doing a lot of processing for each row on the client side, or if the output is sent to a screen on which the user may type a ^S (stop scroll). This ties up the server and prevent other threads from updating any tables from which the data is being fetched.

When using mysql_use_result(), you must execute mysql_fetch_row() until a NULL value is returned, otherwise, the unfetched rows are returned as part of the result set for your next query. The C API gives the error Commands out of sync; you can't run this command now if you forget to do this!

You may not use mysql_data_seek(), mysql_row_seek(), mysql_row_tell(), mysql_num_rows(), or mysql_affected_rows() with a result returned from mysql_use_result(), nor may you issue other queries until mysql_use_result() has finished. (However, after you have fetched all the rows, mysql_num_rows() accurately returns the number of rows fetched.)

You must call mysql_free_result() once you are done with the result set.

Return Values
A MYSQL_RES result structure. NULL if an error occurred.
"""=#
function useresult(mysql::MYSQL)
    return MYSQL_RES(mysql_use_result(mysql.ptr))
end
