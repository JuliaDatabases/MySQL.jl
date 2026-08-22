# Finalizer-free transport reclamation.
#
# A handle's finalizer must not do transport I/O (`close(::Reseau.TLS.Conn)` sends
# close_notify and takes locks). Instead the finalizer obtains a package-global queue
# trylock, flips the handle's `ReapEntry` from `:live` to `:pending` with a CAS, and pushes
# the entry;
# a timer-driven reaper task closes the transports later. Exactly-once is guaranteed by the
# CAS: explicit `retire!` performs the same transition, so a finalizer can never re-enqueue a
# handle that was closed explicitly, and an entry never holds a closed transport.

mutable struct ReapEntry
    @atomic state::Symbol          # :live → :pending → :closing → :closed
    transport::Union{Nothing, P.Transport}
end

ReapEntry(transport::P.Transport) = ReapEntry(:live, transport)

const REAPER_LOCK = Threads.SpinLock()
const REAPER_QUEUE = ReapEntry[]
const REAPER_TIMER = Ref{Union{Nothing, Timer}}(nothing)
const REAPER_INTERVAL_S = 0.5
const REAPER_STATS = Ref((enqueued=0, closed=0))

# Called from finalizers: may only trylock, may not yield. `reregister` re-arms the finalizer
# when the lock is busy (the Julia-manual pattern for finalizers that need locks).
function enqueue_from_finalizer!(entry::ReapEntry, reregister::F) where {F}
    if trylock(REAPER_LOCK)
        try
            _, swapped = @atomicreplace entry.state :live => :pending
            swapped || return nothing
            push!(REAPER_QUEUE, entry)
            REAPER_STATS[] = (enqueued=REAPER_STATS[].enqueued + 1, closed=REAPER_STATS[].closed)
        finally
            unlock(REAPER_LOCK)
        end
    else
        reregister()
    end
    return nothing
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
    batch = ReapEntry[]
    lock(REAPER_LOCK)
    try
        append!(batch, REAPER_QUEUE)
        empty!(REAPER_QUEUE)
    finally
        unlock(REAPER_LOCK)
    end
    n = 0
    for entry in batch
        _, swapped = @atomicreplace entry.state :pending => :closing
        swapped || continue
        t = entry.transport
        entry.transport = nothing
        t === nothing || P.transport_close(t)
        @atomic entry.state = :closed
        n += 1
    end
    n > 0 && lock(() -> (REAPER_STATS[] = (enqueued=REAPER_STATS[].enqueued, closed=REAPER_STATS[].closed + n)), REAPER_LOCK)
    return n
end

pending_reaps() = lock(() -> length(REAPER_QUEUE), REAPER_LOCK)

const REAPER_SETUP_LOCK = ReentrantLock()

# Starts the timer once. A ReentrantLock (not the finalizer-safe spinlock) because creating a
# Timer and registering the atexit hook may yield.
function ensure_reaper!()
    lock(REAPER_SETUP_LOCK)
    try
        REAPER_TIMER[] === nothing || return nothing
        REAPER_TIMER[] = Timer(REAPER_INTERVAL_S; interval=REAPER_INTERVAL_S) do _
            try
                reap_now!()
            catch err
                @warn "MySQL.Native reaper failed" exception=(err, catch_backtrace()) maxlog=10
            end
        end
        atexit(() -> (try; reap_now!(); catch; end; nothing))
    finally
        unlock(REAPER_SETUP_LOCK)
    end
    return nothing
end
