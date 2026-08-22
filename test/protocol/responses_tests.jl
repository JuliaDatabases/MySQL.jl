const CAPS41 = P.CLIENT_PROTOCOL_41 | P.CLIENT_TRANSACTIONS
const CAPS_TRACK = CAPS41 | P.CLIENT_SESSION_TRACK | P.CLIENT_DEPRECATE_EOF

# A packet view with explicit physical framing (for the 0xFE terminator rule).
function pv(payload::Vector{UInt8}; first_chunk_len::Int=length(payload), nchunks::Int=1)
    return P.PacketView(payload, 1, length(payload), 0x00, nchunks, first_chunk_len)
end

function ok_payload(; header=0x00, affected=0, insert_id=0, status=0x0002, warnings=0, info="", state=UInt8[], track::Bool=false)
    buf = UInt8[header]
    P.write_lenenc!(buf, affected)
    P.write_lenenc!(buf, insert_id)
    P.write_u16!(buf, status)
    P.write_u16!(buf, warnings)
    if track
        (isempty(info) && isempty(state)) && return buf
        P.write_lenenc_string!(buf, info)
        isempty(state) || P.write_lenenc_bytes!(buf, state)
    else
        P.write_string!(buf, info)
    end
    return buf
end

function state_block(type, parts::String...)
    data = UInt8[]
    for part in parts
        P.write_lenenc_string!(data, part)
    end
    buf = UInt8[type]
    P.write_lenenc_bytes!(buf, data)
    return buf
end

@testset "responses" begin
    @testset "OK" begin
        ok = P.parse_ok(view_of(Vectors.OK_EXAMPLE), CAPS41, P.Limits())
        @test ok.affected_rows == 0 && ok.last_insert_id == 0
        @test ok.status == P.SERVER_STATUS_AUTOCOMMIT && ok.warnings == 0
        @test ok.info == "" && !ok.is_eof && isempty(ok.session_state)
        ok = P.parse_ok(pv(ok_payload(; affected=3, insert_id=251, info="Rows matched: 3")), CAPS41, P.Limits())
        @test ok.affected_rows == 3 && ok.last_insert_id == 251 && ok.info == "Rows matched: 3"
        # DEPRECATE_EOF terminator form
        @test P.parse_ok(pv(ok_payload(; header=0xFE)), CAPS41, P.Limits()).is_eof
        @test_throws P.ProtocolError P.parse_ok(pv(UInt8[0x00, 0x00]), CAPS41, P.Limits())
        @test_throws P.ProtocolError P.parse_ok(pv(UInt8[0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]), CAPS41, P.Limits())
        # pre-4.1 layout: status only with CLIENT_TRANSACTIONS, info as string<EOF>
        ok = P.parse_ok(pv(UInt8[0x00, 0x01, 0x00, 0x02, 0x00, 0x68, 0x69]), P.CLIENT_TRANSACTIONS, P.Limits())
        @test ok.affected_rows == 1 && ok.status == 2 && ok.info == "hi"
    end

    @testset "OK with session state tracking" begin
        state = vcat(state_block(P.SESSION_TRACK_SYSTEM_VARIABLES, "autocommit", "OFF"), state_block(P.SESSION_TRACK_SCHEMA, "test"), state_block(P.SESSION_TRACK_STATE_CHANGE, "1"))
        payload = ok_payload(; status=P.SERVER_STATUS_AUTOCOMMIT | P.SERVER_SESSION_STATE_CHANGED, info="", state=state, track=true)
        ok = P.parse_ok(pv(payload), CAPS_TRACK, P.Limits())
        @test ok.info == ""
        @test P.system_variables(ok) == ["autocommit" => "OFF"]
        @test P.schema_change(ok) == "test"
        @test length(ok.session_state) == 3
        # MariaDB packs several variable pairs into one block
        multi = UInt8[]
        for s in ("character_set_client", "utf8mb4", "time_zone", "SYSTEM")
            P.write_lenenc_string!(multi, s)
        end
        block = UInt8[P.SESSION_TRACK_SYSTEM_VARIABLES]
        P.write_lenenc_bytes!(block, multi)
        ok = P.parse_ok(pv(ok_payload(; status=P.SERVER_SESSION_STATE_CHANGED, info="x", state=block, track=true)), CAPS_TRACK, P.Limits())
        @test P.system_variables(ok) == ["character_set_client" => "utf8mb4", "time_zone" => "SYSTEM"]
        @test P.schema_change(ok) === nothing
        # no state when the flag is clear even if bytes follow (info only)
        ok = P.parse_ok(pv(ok_payload(; info="changed", track=true)), CAPS_TRACK, P.Limits())
        @test ok.info == "changed" && isempty(ok.session_state)
        # bounded by max_session_state_bytes
        @test_throws P.ProtocolError P.parse_ok(pv(payload), CAPS_TRACK, P.Limits(; max_session_state_bytes=8))
        # truncated state block
        @test_throws P.ProtocolError P.parse_ok(pv(ok_payload(; status=P.SERVER_SESSION_STATE_CHANGED, info="", state=UInt8[0x00, 0x05, 0x01], track=true)), CAPS_TRACK, P.Limits())
    end

    @testset "ERR" begin
        e = P.parse_err(view_of(Vectors.ERR_EXAMPLE), CAPS41)
        @test e.code == 1096 && e.sqlstate == "HY000" && e.msg == "No tables used"
        @test P.Error(e) isa P.Error && P.Error(e).errno == 0x0448 && P.Error(e).sqlstate == "HY000"
        @test sprint(showerror, P.Error(e)) == "(1096): No tables used"
        @test P.StmtError(e) isa P.StmtError && !(P.StmtError(e) isa P.Error)
        # without PROTOCOL_41 the '#' is part of the message
        e = P.parse_err(view_of(Vectors.ERR_EXAMPLE), P.CLIENT_TRANSACTIONS)
        @test e.sqlstate == "" && e.msg == "#HY000No tables used"
        # a message without the marker
        e = P.parse_err(pv(vcat(UInt8[0xFF, 0x28, 0x04], codeunits("plain"))), CAPS41)
        @test e.code == 1064 && e.sqlstate == "" && e.msg == "plain"
        @test_throws P.ProtocolError P.parse_err(pv(UInt8[0xFF, 0xDD, 0x07]), CAPS41)     # 2013 client-reserved
        @test_throws P.ProtocolError P.parse_err(pv(UInt8[0xFF, 0xFF, 0xFF, 0x01]), CAPS41)  # MariaDB progress
        @test_throws P.ProtocolError P.parse_err(pv(UInt8[0xFF, 0x28]), CAPS41)
    end

    @testset "EOF" begin
        eof = P.parse_eof(view_of(Vectors.EOF_EXAMPLE), CAPS41)
        @test eof.warnings == 0 && eof.status == P.SERVER_STATUS_AUTOCOMMIT
        @test P.is_eof_packet(view_of(Vectors.EOF_EXAMPLE))
        @test !P.is_eof_packet(pv(vcat(UInt8[0xFE], zeros(UInt8, 9))))
        @test !P.more_results(eof)
        @test P.more_results(P.EOFPacket(0, P.SERVER_MORE_RESULTS_EXISTS | P.SERVER_STATUS_AUTOCOMMIT))
        @test_throws P.ProtocolError P.parse_eof(pv(UInt8[0xFE, 0x00]), CAPS41)
    end

    @testset "column definitions (vendor vectors)" begin
        d = P.parse_column_def(view_of(Vectors.COLUMN_DEF_PARAM))
        @test d.catalog == "def" && d.schema == "" && d.table == "" && d.org_table == ""
        @test d.name == "?" && d.org_name == ""
        @test d.charset == 63 && d.length == 0 && d.type == P.MYSQL_TYPE_VAR_STRING
        @test d.flags == P.BINARY_FLAG && d.decimals == 0
        @test P.is_binary(d) && !P.is_not_null(d) && !P.is_unsigned(d)
        d = P.parse_column_def(view_of(Vectors.COLUMN_DEF_COL1))
        @test d.name == "col1" && d.decimals == 0x1F
        @test P.field_type_name(d.type) == "VAR_STRING"
        @test occursin("col1", sprint(show, d))
        @test_throws P.ProtocolError P.parse_column_def(pv(Vectors.payload(Vectors.COLUMN_DEF_COL1)[1:12]))
        # The fixed-length block is exactly 0x0C, not an extensible minimum.
        for fixed in UInt8[0x0A, 0x0B, 0x0D]
            bad = copy(Vectors.payload(Vectors.COLUMN_DEF_COL1))
            bad[14] = fixed
            fixed > 0x0C && append!(bad, zeros(UInt8, fixed - 0x0C))
            @test_throws P.ProtocolError P.parse_column_def(pv(bad))
        end
        # MariaDB extended metadata is skipped only when negotiated
        ext = copy(Vectors.payload(Vectors.COLUMN_DEF_COL1))
        insert!(ext, 14, 0x04)
        for b in reverse(codeunits("json"))
            insert!(ext, 15, b)
        end
        @test P.parse_column_def(pv(ext); extended_metadata=true).name == "col1"
        @test_throws P.ProtocolError P.parse_column_def(pv(ext))
    end

    @testset "classification is phase-specific" begin
        @test P.classify_greeting(pv(UInt8[0x0A, 0x00])) == :greeting
        @test P.classify_greeting(pv(UInt8[0xFF, 0x00, 0x00])) == :initial_err
        @test_throws P.ProtocolError P.classify_greeting(pv(UInt8[0x0B]))
        @test P.classify_auth(pv(UInt8[0x00]), false) == :ok
        @test P.classify_auth(pv(UInt8[0xFF]), false) == :err
        @test P.classify_auth(pv(UInt8[0xFE]), false) == :old_auth_switch
        @test P.classify_auth(pv(UInt8[0xFE, 0x61, 0x00]), false) == :auth_switch
        @test P.classify_auth(pv(UInt8[0x01, 0x03]), false) == :auth_more
        @test P.classify_auth(pv(UInt8[0x02, 0x61, 0x00]), false) == :auth_next_factor
        @test_throws P.ProtocolError P.classify_auth(pv(UInt8[0x05]), false)
        @test P.classify_auth(pv(UInt8[0x05]), true) == :plugin_data
        @test P.classify_auth(pv(UInt8[0x02, 0x61]), true) == :plugin_data
        @test P.classify_auth(pv(UInt8[0x01, 0x03]), true) == :plugin_data
        @test_throws P.ProtocolError P.classify_auth(pv(UInt8[]), true)
        @test P.classify_command_response(P.CMD_SIMPLE, pv(UInt8[0x00])) == :ok
        @test P.classify_command_response(P.CMD_SIMPLE, pv(UInt8[0xFF])) == :err
        @test_throws P.ProtocolError P.classify_command_response(P.CMD_SIMPLE, pv(UInt8[0x01]))
        @test_throws P.ProtocolError P.classify_command_response(P.CMD_SIMPLE, pv(UInt8[]))
        @test P.classify_command_response(P.CMD_QUERY, pv(UInt8[0xFB, 0x2F])) == :local_infile
        @test P.classify_command_response(P.CMD_QUERY, pv(UInt8[0x03])) == :column_count
        @test P.classify_command_response(P.CMD_QUERY, pv(UInt8[0xFC, 0x00, 0x01])) == :column_count
        @test_throws P.ProtocolError P.classify_command_response(P.CMD_QUERY, pv(UInt8[0xFE, 1, 2, 3, 4, 5, 6, 7, 8]))
        @test_throws P.ProtocolError P.classify_command_response(P.CMD_STMT_EXECUTE, pv(UInt8[0xFB, 0x2F]))
        @test P.classify_command_response(P.CMD_STMT_PREPARE, pv(UInt8[0x00])) == :prepare_ok
        @test_throws P.ProtocolError P.classify_command_response(P.CMD_STMT_PREPARE, pv(UInt8[0x03]))
        # rows
        @test P.classify_row(pv(UInt8[0x03, 0x61, 0x62, 0x63]), false) == :row
        @test P.classify_row(pv(UInt8[0xFB]), false) == :row                     # NULL first column
        @test P.classify_row(pv(UInt8[0x00]), false) == :row                     # empty string first column
        @test P.classify_row(pv(UInt8[0xFE, 0, 0, 2, 0]), false) == :terminator
        @test P.classify_row(pv(vcat(UInt8[0xFE], zeros(UInt8, 20))), false) == :terminator   # OK-as-EOF with session state
        @test P.classify_row(pv(UInt8[0xFE, 0, 0, 0, 0, 1, 0, 0, 0]; first_chunk_len=P.MAX_CHUNK, nchunks=2), false) == :row
        @test P.classify_row(pv(UInt8[0xFF, 0x28, 0x04]), false) == :err
        @test P.classify_row(pv(UInt8[0x00, 0x00, 0x06]), true) == :row
        @test_throws P.ProtocolError P.classify_row(pv(UInt8[0x05]), true)
        @test_throws P.ProtocolError P.classify_row(pv(UInt8[]), false)
    end

    @testset "scan_text_row!" begin
        offsets, lengths = Int[], Int[]
        row = vcat(UInt8[0x03], codeunits("foo"), UInt8[0xFB, 0x00])
        P.scan_text_row!(pv(row), 3, offsets, lengths)
        @test lengths == [3, -1, 0]
        @test String(row[offsets[1]:(offsets[1] + lengths[1] - 1)]) == "foo"
        @test_throws P.ProtocolError P.scan_text_row!(pv(row), 2, offsets, lengths)   # trailing bytes
        @test_throws P.ProtocolError P.scan_text_row!(pv(row), 4, offsets, lengths)   # truncated
        @test_throws P.ProtocolError P.scan_text_row!(pv(UInt8[0x05, 0x61]), 1, offsets, lengths)
    end
end
