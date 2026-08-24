const ROOT = normpath(joinpath(@__DIR__, ".."))
const NATIVE_DIRS = (joinpath(ROOT, "src"),)
const FORBIDDEN = (
    r"MariaDB_Connector_C_jll",
    r"\blibmariadb\b",
    r"\bAPI\.(?:MYSQL|MYSQL_STMT|MYSQL_RES|MYSQL_BIND)\b",
    r"\bAPI\.mysql_(?:init|options|real_connect|real_query|store_result|use_result|fetch_row|stmt_init|stmt_prepare|stmt_execute)\b",
)

function source_files()
    files = String[]
    for dir in NATIVE_DIRS
        for (root, _, names) in walkdir(dir)
            for name in names
                endswith(name, ".jl") && push!(files, joinpath(root, name))
            end
        end
    end
    return sort!(files)
end

function check_file!(violations::Vector{String}, path::String)
    relative = relpath(path, ROOT)
    for (line_number, line) in enumerate(eachline(path))
        for pattern in FORBIDDEN
            occursin(pattern, line) && push!(violations, "$relative:$line_number: forbidden native dependency reference")
        end
        occursin(r"\bccall\s*\(", line) && relative != joinpath("src", "Protocol", "crypto.jl") &&
            push!(violations, "$relative:$line_number: ccall is allowed only for the OpenSSL RSA wrapper")
    end
    return nothing
end

function main()
    violations = String[]
    files = source_files()
    foreach(path -> check_file!(violations, path), files)
    isempty(violations) || error("native clean-room check failed:\n" * join(violations, '\n'))
    println("native clean-room check: $(length(files)) source files, no forbidden references")
    return nothing
end

main()
