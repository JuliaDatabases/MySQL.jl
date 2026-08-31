using Documenter, MySQL

makedocs(;
    modules=[MySQL],
    checkdocs=:exports,
    format=Documenter.HTML(
        assets=String[],
        repolink="https://github.com/JuliaDatabases/MySQL.jl",
    ),
    pages=[
        "Home" => "index.md",
        "Migrating from 1.x" => "migration.md",
    ],
    repo="https://github.com/JuliaDatabases/MySQL.jl/blob/{commit}{path}#L{line}",
    sitename="MySQL.jl",
    authors="Jacob Quinn",
)

deploydocs(;
    repo="github.com/JuliaDatabases/MySQL.jl",
    devbranch = "main"
)
