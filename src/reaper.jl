# Finalizer-free transport reclamation.
#
# A handle's finalizer must not do transport I/O (`close(::Reseau.TLS.Conn)` sends
# close_notify and takes locks). Instead the finalizer obtains a package-global queue
# trylock, flips the handle's `ReapEntry` from `:live` to `:pending` with a CAS, and links
# the entry into an intrusive queue. A timer-driven reaper task closes the transports later.
# Exactly-once is guaranteed by the
# CAS: explicit `retire!` performs the same transition, so a finalizer can never re-enqueue a
# handle that was closed explicitly, and an entry never holds a closed transport.

# `Base.finalizer` registers under `@nospecialize`, which `--trim=safe` reports as an
# unresolved finalizer; this registers through the same runtime entry Base uses, with
# concrete argument types at every call site.
trim_finalizer!(f::F, o::T) where {F, T} = return (ccall(:jl_gc_add_finalizer_th, Cvoid, (Ptr{Cvoid}, Any, Any), Core.getptls(), o, f); nothing)

mutable struct ReapEntry
    @atomic state::Symbol          # :live → :pending → :closing → :closed
    transport::Union{Nothing, P.Transport}
    next::Union{Nothing, ReapEntry}
end

ReapEntry(transport::P.Transport) = return ReapEntry(:live, transport, nothing)

const REAPER_LOCK = Threads.SpinLock()
const REAPER_QUEUE = Ref{Union{Nothing, ReapEntry}}(nothing)
const REAPER_QUEUE_LENGTH = Ref(0)
const REAPER_TIMER = Ref{Union{Nothing, Timer}}(nothing)
const REAPER_INTERVAL_S = 0.5
const REAPER_STATS = Ref((enqueued=0, closed=0))

# Called from finalizers: may only trylock, may not yield or allocate. The intrusive list
# uses the entry's preallocated `next` field. A false return asks the caller to re-register
# its finalizer using the Julia-manual pattern for finalizers that need locks.
function enqueue_from_finalizer!(entry::ReapEntry)
    if trylock(REAPER_LOCK)
        try
            _, swapped = @atomicreplace entry.state :live => :pending
            swapped || return true
            entry.next = REAPER_QUEUE[]
            REAPER_QUEUE[] = entry
            REAPER_QUEUE_LENGTH[] += 1
            REAPER_STATS[] = (enqueued=REAPER_STATS[].enqueued + 1, closed=REAPER_STATS[].closed)
        finally
            unlock(REAPER_LOCK)
        end
        return true
    end
    return false
end

"""
    retire!(entry)

Explicit-close path: claims the entry (`:live → :closed`) so the finalizer never enqueues it,
and returns the transport to close (or `nothing` if the reaper already owns it).
"""
function retire!(entry::ReapEntry)
    _, swapped = @atomicreplace entry.state :live => :closed
    swapped || return nothing
    t = entry.transport
    entry.transport = nothing
    return t
end

"""
    reap_now!() -> Int

Closes every queued transport (outside the lock) and returns how many were closed.
"""
function reap_now!()
    batch = nothing
    lock(REAPER_LOCK)
    try
        batch = REAPER_QUEUE[]
        REAPER_QUEUE[] = nothing
        REAPER_QUEUE_LENGTH[] = 0
    finally
        unlock(REAPER_LOCK)
    end
    n = 0
    entry = batch
    while entry !== nothing
        next = entry.next
        entry.next = nothing
        _, swapped = @atomicreplace entry.state :pending => :closing
        if swapped
            t = entry.transport
            entry.transport = nothing
            # The timer task's world age is fixed at its creation, but `P.Transport` is a
            # closed union of concrete types whose `close` methods all predate any timer,
            # so a plain call can never be a world-age MethodError (which `transport_close`
            # would swallow, leaving the transport unclosed while the entry reads :closed).
            t === nothing || P.transport_close(t)
            @atomic entry.state = :closed
            n += 1
        end
        entry = next
    end
    n > 0 && lock(() -> (REAPER_STATS[] = (enqueued=REAPER_STATS[].enqueued, closed=REAPER_STATS[].closed + n)), REAPER_LOCK)
    return n
end

pending_reaps() = return lock(() -> REAPER_QUEUE_LENGTH[], REAPER_LOCK)

const REAPER_SETUP_LOCK = ReentrantLock()

# Named functions (not closures) so a `juliac --trim` build can compile them: runtime
# callbacks (timer ticks, atexit hooks) are invoked dynamically, and their specializations
# are registered as entrypoints in MySQL.jl.
function reaper_tick(::Timer)
    try
        reap_now!()
    catch err
        @warn "MySQL reaper failed" exception=(err, catch_backtrace()) maxlog=10
    end
    return nothing
end

reaper_atexit() = return (try; reap_now!(); catch; end; nothing)

# Starts the timer once. A ReentrantLock (not the finalizer-safe spinlock) because creating a
# Timer and registering the atexit hook may yield.
function ensure_reaper!()
    lock(REAPER_SETUP_LOCK)
    try
        REAPER_TIMER[] === nothing || return nothing
        REAPER_TIMER[] = Timer(reaper_tick, REAPER_INTERVAL_S; interval=REAPER_INTERVAL_S)
        atexit(reaper_atexit)
    finally
        unlock(REAPER_SETUP_LOCK)
    end
    return nothing
end
