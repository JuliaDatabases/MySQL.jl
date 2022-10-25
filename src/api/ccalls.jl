macro c(func, ret, args, vals...)
    if Sys.iswindows()
        esc(quote
            ret = ccall( ($func, libmariadb), stdcall, $ret, $args, $(vals...))
        end)
    else
        esc(quote
            ret = ccall( ($func, libmariadb),          $ret, $args, $(vals...))
        end)
    end
end

struct MY_CHARSET_INFO
    number::Cuint
    state::Cuint
    csname::Ptr{UInt8}
    name::Ptr{UInt8}
    comment::Ptr{UInt8}
    dir::Ptr{UInt8}
    mbminlen::Cuint
    mbmaxlen::Cuint
end

# "uint64_t mysql_affected_rows(MYSQL *mysql)"
function mysql_affected_rows(mysql::Ptr{Cvoid})
    return @c(:mysql_affected_rows,
                 UInt64,
                 (Ptr{Cvoid}, ),
                 mysql)
end

#bool mysql_autocommit(MYSQL *mysql, bool mode)
function mysql_autocommit(mysql::Ptr{Cvoid}, mode)
    return @c(:mysql_autocommit,
                 Cchar, (Ptr{Cvoid}, Cchar),
                 mysql, mode)
end

#bool mysql_change_user(MYSQL *mysql, const char *user, const char *password, const char *db)
function mysql_change_user(mysql::Ptr{Cvoid}, user::AbstractString, password::AbstractString, db)
    return @c(:mysql_change_user,
                Bool,
                (Ptr{Cvoid}, Cstring, Cstring, Cstring),
                mysql, user, password, db)
end

#const char *mysql_character_set_name(MYSQL *mysql)
function mysql_character_set_name(mysql::Ptr{Cvoid})
    return @c(:mysql_character_set_name,
                 Culong,
                 (Ptr{Cvoid}, ),
                 mysql)
end

#struct st_mysql_client_plugin *mysql_client_find_plugin(MYSQL *mysql, const char *name, int type)
function mysql_client_find_plugin(mysql::Ptr{Cvoid}, name::AbstractString, type::Int)
    return @c(:mysql_client_find_plugin,
                Ptr{Cvoid},
                (Ptr{Cvoid}, Cstring, Cint),
                mysql, name, type)
end

#struct st_mysql_client_plugin *mysql_client_register_plugin(MYSQL *mysql, struct st_mysql_client_plugin *plugin)
function mysql_client_register_plugin(mysql::Ptr{Cvoid}, plugin::Ptr{Cvoid})
    return @c(:mysql_client_register_plugin,
                Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{Cvoid}),
                mysql, plugin)
end

#void mysql_close(MYSQL *mysql)
function mysql_close(mysql::Ptr{Cvoid})
    return @c(:mysql_close,
                 Cvoid,
                 (Ptr{Cvoid}, ),
                 mysql)
end

function mysql_commit(mysql::Ptr{Cvoid})
    return @c(:mysql_commit,
                Bool,
                (Ptr{Cvoid},),
                mysql)
end

#void mysql_data_seek(MYSQL_RES *result, uint64_t offset)
function mysql_data_seek(result::Ptr{Cvoid}, offset::Integer)
    return @c(:mysql_data_seek,
                Cvoid,
                (Ptr{Cvoid}, UInt64),
                result, offset)
end

function mysql_dump_debug_info(mysql::Ptr{Cvoid})
    return @c(:mysql_dump_debug_info,
                Cint,
                (Ptr{Cvoid},),
                mysql)
end

#unsigned int mysql_errno(MYSQL *mysql)
function mysql_errno(mysql::Ptr{Cvoid})
    return @c(:mysql_errno,
                 Cuint,
                 (Ptr{Cvoid}, ),
                 mysql)
end

#const char *mysql_error(MYSQL *mysql)
function mysql_error(mysql::Ptr{Cvoid})
    return @c(:mysql_error,
                 Ptr{UInt8},
                 (Ptr{Cvoid}, ),
                 mysql)
end


#MYSQL_FIELD *mysql_fetch_field(MYSQL_RES *result)
function mysql_fetch_field(result::Ptr{Cvoid})
    return @c(:mysql_fetch_field,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                result)
end

#MYSQL_FIELD *mysql_fetch_field_direct(MYSQL_RES *result, unsigned int fieldnr)
function mysql_fetch_field_direct(result::Ptr{Cvoid}, fieldnr::Integer)
    return @c(:mysql_fetch_field_direct,
                Ptr{Cvoid},
                (Ptr{Cvoid}, Cuint),
                result, fieldnr)
end

#Returns the field metadata
function mysql_fetch_fields(results::Ptr{Cvoid})
    return @c(:mysql_fetch_fields,
                 Ptr{Cvoid},
                 (Ptr{Cvoid}, ),
                 results)
end

#unsigned long *mysql_fetch_lengths(MYSQL_RES *result)
function mysql_fetch_lengths(result::Ptr{Cvoid})
    return @c(:mysql_fetch_lengths,
                Ptr{Culong},
                (Ptr{Cvoid},),
                result)
end

#Returns the row from the result set.
function mysql_fetch_row(results::Ptr{Cvoid})
    return @c(:mysql_fetch_row,
                 Ptr{Ptr{UInt8}},
                 (Ptr{Cvoid}, ),
                 results)
end

#Returns the number of columns for the most recent query on the connection.
function mysql_field_count(mysql::Ptr{Cvoid})
    return @c(:mysql_field_count,
                 Cuint,
                 (Ptr{Cvoid}, ),
                 mysql)
end

#MYSQL_FIELD_OFFSET mysql_field_seek(MYSQL_RES *result, MYSQL_FIELD_OFFSET offset)
function mysql_field_seek(result::Ptr{Cvoid}, offset::Integer)
    return @c(:mysql_field_seek,
                Cuint,
                (Ptr{Cvoid}, Cuint),
                result, offset)
end

function mysql_field_tell(result::Ptr{Cvoid})
    return @c(:mysql_field_tell,
                Cuint,
                (Ptr{Cvoid},),
                result)
end

#Frees the result set.
function mysql_free_result(result::Ptr{Cvoid})
    return @c(:mysql_free_result,
                 Ptr{Cvoid},
                 (Ptr{Cvoid}, ),
                 result)
end

#void mysql_get_character_set_info(MYSQL *mysql, MY_CHARSET_INFO *cs)
function mysql_get_character_set_info(mysql::Ptr{Cvoid}, cs::Ref{MY_CHARSET_INFO})
    return @c(:mysql_get_character_set_info,
                Cvoid,
                (Ptr{Cvoid}, Ref{MY_CHARSET_INFO}),
                mysql, cs)
end

#const char *mysql_get_client_info(void)
function mysql_get_client_info()
    return @c(:mysql_get_client_info,
                Ptr{UInt8},
                ())
end

function mysql_get_client_version()
    return @c(:mysql_get_client_version,
                Culong,
                ())
end

function mysql_get_host_info(mysql::Ptr{Cvoid})
    return @c(:mysql_get_host_info,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                mysql)
end

#int mysql_get_option(MYSQL *mysql, enum mysql_option option, const void *arg)
function mysql_get_option(mysql::Ptr{Cvoid}, option::Integer, arg::Ref{Cuint})
    return @c(:mysql_get_option,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{Cuint}),
                mysql, option, arg)
end

function mysql_get_option(mysql::Ptr{Cvoid}, option::Integer, arg::Ref{Culong})
    return @c(:mysql_get_option,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{Culong}),
                mysql, option, arg)
end

function mysql_get_option(mysql::Ptr{Cvoid}, option::Integer, arg::Ref{Bool})
    return @c(:mysql_get_option,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{Bool}),
                mysql, option, arg)
end

function mysql_get_option(mysql::Ptr{Cvoid}, option::Integer, arg::Ptr{Cvoid})
    return @c(:mysql_get_option,
                Cint,
                (Ptr{Cvoid}, Cint, Ptr{Cvoid}),
                mysql, option, arg)
end

#unsigned int mysql_get_proto_info(MYSQL *mysql)
function mysql_get_proto_info(mysql::Ptr{Cvoid})
    return @c(:mysql_get_proto_info,
                Cuint,
                (Ptr{Cvoid},),
                mysql)
end

#const char *mysql_get_server_info(MYSQL *mysql)
function mysql_get_server_info(mysql::Ptr{Cvoid})
    return @c(:mysql_get_server_info,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                mysql)
end

function mysql_get_server_version(mysql::Ptr{Cvoid})
    return @c(:mysql_get_server_version,
                Culong,
                (Ptr{Cvoid},),
                mysql)
end

function mysql_get_ssl_cipher(mysql::Ptr{Cvoid})
    return @c(:mysql_get_ssl_cipher,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                mysql)
end

#unsigned long mysql_hex_string(char *to, const char *from, unsigned long length)
function mysql_hex_string(to, from, length::Integer)
    return @c(:mysql_hex_string,
                Culong,
                (Cstring, Cstring, Culong),
                to, from, length)
end

#const char *mysql_info(MYSQL *mysql)
function mysql_info(mysql::Ptr{Cvoid})
    return @c(:mysql_info,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                mysql)
end

#MYSQL *mysql_init(MYSQL *mysql)
function mysql_init(mysql::Ptr{Cvoid})
    return @c(:mysql_init,
                 Ptr{Cvoid},
                 (Ptr{Cvoid}, ),
                 mysql)
end

#uint64_t mysql_insert_id(MYSQL *mysql)
function mysql_insert_id(mysql::Ptr{Cvoid})
    return @c(:mysql_insert_id,
                 Int64,
                 (Ptr{Cvoid}, ),
                 mysql)
end

#bool mysql_more_results(MYSQL *mysql)
function mysql_more_results(mysql::Ptr{Cvoid})
    return @c(:mysql_more_results,
                Bool,
                (Ptr{Cvoid},),
                mysql)
end

#int mysql_next_result(MYSQL *mysql)
function mysql_next_result(mysql::Ptr{Cvoid})
    return @c(:mysql_next_result,
                Cint,
                (Ptr{Cvoid},),
                mysql)
end

#unsigned int mysql_num_fields(MYSQL_RES *result)
function mysql_num_fields(results::Ptr{Cvoid})
    return @c(:mysql_num_fields,
                 Cuint,
                 (Ptr{Cvoid}, ),
                 results)
end

#uint64_t mysql_num_rows(MYSQL_RES *result)
function mysql_num_rows(results::Ptr{Cvoid})
    return @c(:mysql_num_rows,
                 UInt64,
                 (Ptr{Cvoid}, ),
                 results)
end

#int mysql_options(MYSQL *mysql, enum mysql_option option, const void *arg)
function mysql_options(mysql::Ptr{Cvoid}, option::mysql_option, arg::Ref{Cuint})
    return @c(:mysql_options,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{Cuint}),
                mysql, option, arg)
end

function mysql_options(mysql::Ptr{Cvoid}, option::mysql_option, arg::Ref{Culong})
    return @c(:mysql_options,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{Culong}),
                mysql, option, arg)
end

function mysql_options(mysql::Ptr{Cvoid}, option::mysql_option, arg::Ref{Bool})
    return @c(:mysql_options,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{Bool}),
                mysql, option, arg)
end

function mysql_options(mysql::Ptr{Cvoid}, option::mysql_option, arg::Ptr{Cvoid})
    return @c(:mysql_options,
                Cint,
                (Ptr{Cvoid}, Cint, Ptr{Cvoid}),
                mysql, option, arg)
end

#int mysql_options4(MYSQL *mysql, enum mysql_option option, const void *arg1, const void *arg2)
function mysql_options4(mysql::Ptr{Cvoid}, option::mysql_option, arg1::Ref{String}, arg2::Ref{String})
    return @c(:mysql_options4,
                Cint,
                (Ptr{Cvoid}, Cint, Ref{String}, Ref{String}),
                mysql, option, arg1, arg2)
end

#int mysql_ping(MYSQL *mysql)
function mysql_ping(mysql::Ptr{Cvoid})
    return @c(:mysql_ping,
                 Cint,
                 (Ptr{Cvoid}, ),
                 mysql)
end

#int mysql_plugin_options(struct st_mysql_client_plugin *plugin, const char *option, const void *value)
function mysql_plugin_options(plugin::Ptr{Cvoid}, option, value)
    return @c(:mysql_plugin_options,
                Cint,
                (Ptr{Cvoid}, Cstring, Ptr{Cvoid}),
                plugin, option, value)
end

function mysql_query(mysql::Ptr{Cvoid}, stmt_str)
    return @c(:mysql_query,
                 Cint,
                 (Ptr{Cvoid}, Cstring),
                 mysql, stmt_str)
end

#MYSQL *mysql_real_connect(MYSQL *mysql, const char *host, const char *user, const char *passwd, const char *db, unsigned int port, const char *unix_socket, unsigned long client_flag)
function mysql_real_connect(mysql::Ptr{Cvoid}, host, user, passwd, db, port, unix_socket, client_flag)
    return @c(:mysql_real_connect,
                Ptr{Cvoid},
                (Ptr{Cvoid}, Cstring, Cstring, Cstring, Cstring, Cuint, Cstring, Culong),
                mysql, host, user, passwd, db, port, unix_socket, client_flag)
end

#unsigned long mysql_real_escape_string(MYSQL *mysql, char *to, const char *from, unsigned long length)
function mysql_real_escape_string(mysql::Ptr{Cvoid}, to, from, len)
    return @c(:mysql_real_escape_string,
                Culong,
                (Ptr{Cvoid}, Ptr{UInt8}, Cstring, Culong),
                mysql, to, from, len)
end

#unsigned long mysql_real_escape_string_quote(MYSQL *mysql, char *to, const char *from, unsigned long length, char quote)
function mysql_real_escape_string_quote(mysql::Ptr{Cvoid}, to, from, len, q)
    return @c(:mysql_real_escape_string_quote,
                Culong,
                (Ptr{Cvoid}, Ptr{UInt8}, Cstring, Culong, Cchar),
                mysql, to, from, len, q)
end

#int mysql_real_query(MYSQL *mysql, const char *stmt_str, unsigned long length)
function mysql_real_query(mysql::Ptr{Cvoid}, stmt_str, len)
    return @c(:mysql_real_query,
                 Cint,
                 (Ptr{Cvoid}, Cstring, Culong),
                 mysql, stmt_str, len)
end

#int mysql_reset_connection(MYSQL *mysql)
function mysql_reset_connection(mysql::Ptr{Cvoid})
    return @c(:mysql_reset_connection,
                Cint,
                (Ptr{Cvoid},),
                mysql)
end

#void mysql_reset_server_public_key(void)
function mysql_reset_server_public_key()
    return @c(:mysql_reset_server_public_key,
                Cvoid,
                ())
end

#enum enum_resultset_metadata mysql_result_metadata(MYSQL_RES *result)
function mysql_result_metadata(result::Ptr{Cvoid})
    return @c(:mysql_result_metadata,
                Cint,
                (Ptr{Cvoid},),
                result)
end

#bool mysql_rollback(MYSQL *mysql)
function mysql_rollback(mysql::Ptr{Cvoid})
    return @c(:mysql_rollback,
                Bool,
                (Ptr{Cvoid},),
                mysql)
end

#MYSQL_ROW_OFFSET mysql_row_seek(MYSQL_RES *result, MYSQL_ROW_OFFSET offset)
function mysql_row_seek(result::Ptr{Cvoid}, offset::Ptr{Cvoid})
    return @c(:mysql_row_seek,
                Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{Cvoid}),
                result, offset)
end

#MYSQL_ROW_OFFSET mysql_row_tell(MYSQL_RES *result)
function mysql_row_tell(result::Ptr{Cvoid})
    return @c(:mysql_row_tell,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                result)
end

#int mysql_select_db(MYSQL *mysql, const char *db)
function mysql_select_db(mysql::Ptr{Cvoid}, db::AbstractString)
    return @c(:mysql_select_db,
                Cint,
                (Ptr{Cvoid}, Cstring),
                mysql, db)
end

#int mysql_session_track_get_first(MYSQL *mysql, enum enum_session_state_type type, const char **data, size_t *length)
function mysql_session_track_get_first(mysql::Ptr{Cvoid}, type, data, len)
    return @c(:mysql_session_track_get_first,
                Cint,
                (Ptr{Cvoid}, Cint, Ptr{Cstring}, Ptr{Csize_t}),
                mysql, type, data, len)
end

#int mysql_session_track_get_next(MYSQL *mysql, enum enum_session_state_type type, const char **data, size_t *length)
function mysql_session_track_get_next(mysql::Ptr{Cvoid}, type, data, len)
    return @c(:mysql_session_track_get_next,
                Cint,
                (Ptr{Cvoid}, Cint, Ptr{Cstring}, Ptr{Csize_t}),
                mysql, type, data, len)
end

#int mysql_set_character_set(MYSQL *mysql, const char *csname)
function mysql_set_character_set(mysql::Ptr{Cvoid}, csname::AbstractString)
    return @c(:mysql_set_character_set,
                Cint,
                (Ptr{Cvoid}, Cstring),
                mysql, csname)
end

#void mysql_set_local_infile_default(MYSQL *mysql);
function mysql_set_local_infile_default(mysql::Ptr{Cvoid})
    return @c(:mysql_set_local_infile_default,
                Cvoid,
                (Ptr{Cvoid},),
                mysql)
end

#void mysql_set_local_infile_handler(MYSQL *mysql, int (*local_infile_init)(void **, const char *, void *), int (*local_infile_read)(void *, char *, unsigned int), void (*local_infile_end)(void *), int (*local_infile_error)(void *, char*, unsigned int), void *userdata);
function mysql_set_local_infile_handler(mysql::Ptr{Cvoid}, local_infile_init, local_infile_read, local_infile_end, local_infile_error, userdata)
    return @c(:mysql_set_local_infile_handler,
                Cvoid,
                (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                mysql, local_infile_init, local_infile_read, local_infile_end, local_infile_error, userdata)
end

#int mysql_set_server_option(MYSQL *mysql, enum enum_mysql_set_option option)
function mysql_set_server_option(mysql::Ptr{Cvoid}, option)
    return @c(:mysql_set_server_option,
                Cint,
                (Ptr{Cvoid}, Cint),
                mysql, option)
end

#const char *mysql_sqlstate(MYSQL *mysql)
function mysql_sqlstate(mysql::Ptr{Cvoid})
    return @c(:mysql_sqlstate,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                mysql)
end

#bool mysql_ssl_set(MYSQL *mysql, const char *key, const char *cert, const char *ca, const char *capath, const char *cipher)
function mysql_ssl_set(mysql::Ptr{Cvoid}, key, cert, ca, capath, cipher)
    return @c(:mysql_ssl_set,
                Bool,
                (Ptr{Cvoid}, Cstring, Cstring, Cstring, Cstring, Cstring),
                mysql, key, cert, ca, capath, cipher)
end

#const char *mysql_stat(MYSQL *mysql)
function mysql_stat(mysql::Ptr{Cvoid})
    return @c(:mysql_stat,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                mysql)
end

#MYSQL_RES *mysql_store_result(MYSQL *mysql)
function mysql_store_result(mysql::Ptr{Cvoid})
    return @c(:mysql_store_result,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                mysql)
end

#unsigned int mysql_thread_safe(void)
function mysql_thread_safe()
    return @c(:mysql_thread_safe,
                Cuint,
                (),)
end

#MYSQL_RES *mysql_use_result(MYSQL *mysql)
function mysql_use_result(mysql::Ptr{Cvoid})
    return @c(:mysql_use_result,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                mysql)
end

#uint64_t mysql_stmt_affected_rows(MYSQL_STMT *stmt)
function mysql_stmt_affected_rows(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_affected_rows,
                UInt64,
                (Ptr{Cvoid},),
                stmt)
end

#bool mysql_stmt_attr_get(MYSQL_STMT *stmt, enum enum_stmt_attr_type option, void *arg)
function mysql_stmt_attr_get(stmt::Ptr{Cvoid}, option::enum_stmt_attr_type, arg::Ref{Bool})
    return @c(:mysql_stmt_attr_get,
                Bool,
                (Ptr{Cvoid}, Cint, Ref{Bool}),
                stmt, option, arg)
end

function mysql_stmt_attr_get(stmt::Ptr{Cvoid}, option::enum_stmt_attr_type, arg::Ref{Culong})
    return @c(:mysql_stmt_attr_get,
                Bool,
                (Ptr{Cvoid}, Cint, Ref{Culong}),
                stmt, option, arg)
end

#bool mysql_stmt_attr_set(MYSQL_STMT *stmt, enum enum_stmt_attr_type option, const void *arg)
function mysql_stmt_attr_set(stmt::Ptr{Cvoid}, option::enum_stmt_attr_type, arg::Ref{Bool})
    return @c(:mysql_stmt_attr_set,
                Bool,
                (Ptr{Cvoid}, Cint, Ref{Bool}),
                stmt, option, arg)
end

function mysql_stmt_attr_set(stmt::Ptr{Cvoid}, option::enum_stmt_attr_type, arg::Ref{Culong})
    return @c(:mysql_stmt_attr_set,
                Bool,
                (Ptr{Cvoid}, Cint, Ref{Culong}),
                stmt, option, arg)
end

#bool mysql_stmt_bind_param(MYSQL_STMT *stmt, MYSQL_BIND *bind)
function mysql_stmt_bind_param(stmt::Ptr{Cvoid}, bind::Ptr{Cvoid})
    return @c(:mysql_stmt_bind_param,
                Bool,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                stmt, bind)
end

#bool mysql_stmt_bind_result(MYSQL_STMT *stmt, MYSQL_BIND *bind)
function mysql_stmt_bind_result(stmt::Ptr{Cvoid}, bind::Ptr{Cvoid})
    return @c(:mysql_stmt_bind_result,
                Bool,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                stmt, bind)
end

#bool mysql_stmt_close(MYSQL_STMT *stmt)
function mysql_stmt_close(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_close,
                Bool,
                (Ptr{Cvoid},),
                stmt)
end

#void mysql_stmt_data_seek(MYSQL_STMT *stmt, uint64_t offset)
function mysql_stmt_data_seek(stmt::Ptr{Cvoid}, offset::Integer)
    return @c(:mysql_stmt_data_seek,
                Cvoid,
                (Ptr{Cvoid}, UInt64),
                stmt, offset)
end

#unsigned int mysql_stmt_errno(MYSQL_STMT *stmt)
function mysql_stmt_errno(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_errno,
                Cuint,
                (Ptr{Cvoid},),
                stmt)
end

function mysql_stmt_error(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_error,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                stmt)
end

#int mysql_stmt_execute(MYSQL_STMT *stmt)
function mysql_stmt_execute(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_execute,
                Cint,
                (Ptr{Cvoid},),
                stmt)
end

#int mysql_stmt_fetch(MYSQL_STMT *stmt)
function mysql_stmt_fetch(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_fetch,
                Cint,
                (Ptr{Cvoid},),
                stmt)
end

#int mysql_stmt_fetch_column(MYSQL_STMT *stmt, MYSQL_BIND *bind, unsigned int column, unsigned long offset)
function mysql_stmt_fetch_column(stmt::Ptr{Cvoid}, bind::Ptr{Cvoid}, column, offset)
    return @c(:mysql_stmt_fetch_column,
                Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}, Cuint, Culong),
                stmt, bind, column, offset)
end

#unsigned int mysql_stmt_field_count(MYSQL_STMT *stmt)
function mysql_stmt_field_count(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_field_count,
                Cuint,
                (Ptr{Cvoid},),
                stmt)
end

#bool mysql_stmt_free_result(MYSQL_STMT *stmt)
function mysql_stmt_free_result(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_free_result,
                Bool,
                (Ptr{Cvoid},),
                stmt)
end

#MYSQL_STMT *mysql_stmt_init(MYSQL *mysql)
function mysql_stmt_init(mysql::Ptr{Cvoid})
    return @c(:mysql_stmt_init,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                mysql)
end

#uint64_t mysql_stmt_insert_id(MYSQL_STMT *stmt)
function mysql_stmt_insert_id(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_insert_id,
                UInt64,
                (Ptr{Cvoid},),
                stmt)
end

#int mysql_stmt_next_result(MYSQL_STMT *mysql)
function mysql_stmt_next_result(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_next_result,
                Cint,
                (Ptr{Cvoid},),
                stmt)
end

#uint64_t mysql_stmt_num_rows(MYSQL_STMT *stmt)
function mysql_stmt_num_rows(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_num_rows,
                UInt64,
                (Ptr{Cvoid},),
                stmt)
end

#unsigned long mysql_stmt_param_count(MYSQL_STMT *stmt)
function mysql_stmt_param_count(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_param_count,
                Culong,
                (Ptr{Cvoid},),
                stmt)
end

#int mysql_stmt_prepare(MYSQL_STMT *stmt, const char *stmt_str, unsigned long length)
function mysql_stmt_prepare(stmt::Ptr{Cvoid}, stmt_str, len)
    return @c(:mysql_stmt_prepare,
                Cint,
                (Ptr{Cvoid}, Cstring, Culong),
                stmt, stmt_str, len)
end

#bool mysql_stmt_reset(MYSQL_STMT *stmt)
function mysql_stmt_reset(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_reset,
                Bool,
                (Ptr{Cvoid},),
                stmt)
end

#MYSQL_RES *mysql_stmt_result_metadata(MYSQL_STMT *stmt)
function mysql_stmt_result_metadata(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_result_metadata,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                stmt)
end

#MYSQL_ROW_OFFSET mysql_stmt_row_seek(MYSQL_STMT *stmt, MYSQL_ROW_OFFSET offset)
function mysql_stmt_row_seek(stmt::Ptr{Cvoid}, offset::Ptr{Cvoid})
    return @c(:mysql_stmt_row_seek,
                Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{Cvoid}),
                stmt, offset)
end

#MYSQL_ROW_OFFSET mysql_stmt_row_tell(MYSQL_STMT *stmt)
function mysql_stmt_row_tell(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_row_tell,
                Ptr{Cvoid},
                (Ptr{Cvoid},),
                stmt)
end

#bool mysql_stmt_send_long_data(MYSQL_STMT *stmt, unsigned int parameter_number, const char *data, unsigned long length)
function mysql_stmt_send_long_data(stmt::Ptr{Cvoid}, parameter_number, data, length)
    return @c(:mysql_stmt_send_long_data,
                Bool,
                (Ptr{Cvoid}, Cuint, Cstring, Culong),
                stmt, parameter_number, data, length)
end

#const char *mysql_stmt_sqlstate(MYSQL_STMT *stmt)
function mysql_stmt_sqlstate(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_sqlstate,
                Ptr{UInt8},
                (Ptr{Cvoid},),
                stmt)
end

#int mysql_stmt_store_result(MYSQL_STMT *stmt)
function mysql_stmt_store_result(stmt::Ptr{Cvoid})
    return @c(:mysql_stmt_store_result,
                Cint,
                (Ptr{Cvoid},),
                stmt)
end
