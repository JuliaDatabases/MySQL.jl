using Documenter, MySQL

makedocs(;
    modules=[MySQL],
    format=Documenter.HTML(),
    pages=[
        "Home" => "index.md",
        "Migrating from 1.x" => "migration.md",
    ],
    repo="https://github.com/JuliaDatabases/MySQL.jl/blob/{commit}{path}#L{line}",
    sitename="MySQL.jl",
    authors="Jacob Quinn",
    assets=String[],
)

deploydocs(;
    repo="github.com/JuliaDatabases/MySQL.jl",
    devbranch = "main"
)
