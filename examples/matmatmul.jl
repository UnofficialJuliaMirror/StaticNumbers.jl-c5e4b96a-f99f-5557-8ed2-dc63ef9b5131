# For beenchmarking, use: julia -O3

# Note: I'd like to be able to do this with `view`s that result
# in fixed-size subarrays, but at the moment, those are still allocating.
# So passing ranges as separate arguments instead.

# Instead of Julia's `@inbounds` mechanism, we pass `inbounds` explicitly
# as a `FixedOrBool` parameter. This works even when functions are not inlined,
# and makes it easier to eliminate bounds-checking code when using the @code_llvm
# macro.
# It's ugly, but it saves a few nanoseconds...
# Probably future optimizations in Julia will eliminate the need for this.

module MatMatMulExample

using FixedNumbers
using StaticArrays
using LinearAlgebra

# Change this to `false` to enable bounds checking in every function.
const ftrue = Fixed(true)

"A struct that stores the block size used in matmatmul"
struct BlockSize{M<:Integer,N<:Integer,K<:Integer,CP<:FixedOrBool}
    m::M
    n::N
    k::K
    cp::CP
end

const dimerr = DimensionMismatch("Incompatible matrix axes")
const aliaserr = ErrorException("Destination matrix cannot be one of inputs")

"""
Check that ranges are in bounds for `mymul`.
"""
@inline function checkmulbounds(
                A::AbstractMatrix, B::AbstractMatrix, C::AbstractMatrix,
                mm::AbstractRange, nn::AbstractRange, kk::AbstractRange)
        checkbounds(C, mm, nn)
        checkbounds(A, mm, kk)
        checkbounds(B, kk, nn)
end

"""
C <- A*B + beta*C

If `inbounds` is `true` then no check is performed that matrix sizes match
block specifications. This can lead to memory corruption.
"""
function mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
                beta::Number, inbounds::FixedOrBool,
                mnk::BlockSize, mnks::BlockSize...)
    (M,N) = size(C)
    K = size(A,2)
    if !inbounds
        (1:M,1:K) == axes(A) && (1:K,1:N) == axes(B) && (1:M,1:N) == axes(C) || throw(dimerr)
        (C===A || C===B) && throw(aliaserr) # Technically not a boundscheck, but...
    end

    (tm, rm) = divrem(M, mnk.m)
    (tn, rn) = divrem(N, mnk.n)
    (tk, rk) = divrem(K, mnk.k)

    if mnk.cp == true
        A1 = A isa StaticMatrix ? A : @inbounds MMatrix{M,K}(A)
        B1 = B isa StaticMatrix ? B : @inbounds MMatrix{K,N}(B)
        C1 = C isa StaticMatrix ? C : @inbounds MMatrix{M,N}(C)
        mymul!(C1, A1, B1, beta, ftrue,
            tm, tn, tk,
            Fixed(rm), Fixed(rn), Fixed(rk),
            mnk.m, mnk.n, mnk.k,
            mnks...)
        if !(C isa StaticMatrix)
            C .= C1
        end
    else
        mymul!(C, A, B, beta, ftrue,
            tm, tn, tk,
            Fixed(rm), Fixed(rn), Fixed(rk),
            mnk.m, mnk.n, mnk.k,
            mnks...)
    end
end

# C <- A*B
mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix, mnks::BlockSize...) = mymul!(C, A, B, Fixed(false), Fixed(false), mnks...)

function mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
                beta::Number, inbounds::FixedOrBool,
                tm::Integer, tn::Integer, tk::Integer,
                rm::Integer, rn::Integer, rk::Integer,
                m::Integer, n::Integer, k::Integer)
    if !inbounds
        checkmulbounds(A, B, C, Base.OneTo(tm*m+rm), Base.OneTo(tn*n+rn), Base.OneTo(tk*k+rk))
    end
    for i=0:tm-1
        mm = i*m .+ FixedOneTo(m)
        mymul!(C, A, B, beta, ftrue, mm, tn, tk, rn, rk, n, k)
    end
    if rm>0
        mm = tm*m .+ FixedOneTo(rm)
        mymul!(C, A, B, beta, ftrue, mm, tn, tk, rn, rk, n, k)
    end
end

#C[mm,:] <- A[mm,:]*B + beta*C[mm,:]
@inline function mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
        beta::Number, inbounds::FixedOrBool,
        mm::AbstractUnitRange{<:Integer}, tn::Integer, tk::Integer,
        rn::Integer, rk::Integer, n::Integer, k::Integer)
    if !inbounds
        checkmulbounds(inbounds, A, B, C, mm, Base.OneTo(tn*n+rn), Base.OneTo(tk*k+rk))
    end
    for j=0:tn-1
        nn = j*n .+ FixedOneTo(n)
        mymul!(C, A, B, beta, ftrue, mm, nn, tk, rk, k)
    end
    if rn>0
        nn = tn*n .+ FixedOneTo(rn)
        mymul!(C, A, B, beta, ftrue, mm, nn, tk, rk, k)
    end
end

# C[mm,nn] <- A[mm,:]*B[:,nn] + beta*C[mm,nn]
@inline function mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
        beta::Number, inbounds::FixedOrBool,
        mm::AbstractUnitRange{<:Integer}, nn::AbstractUnitRange{<:Integer},
        tk::Integer, rk::Integer, k::Integer)
    if !inbounds
        checkmulbounds(inbounds, A, B, C, mm, nn, Base.OneTo(tk*k+rk))
    end
    X = beta * load(SMatrix, C, mm, nn, ftrue)
    for h=0:tk-1
        kk = h*k .+ FixedOneTo(k)
        X += load(SMatrix, A, mm, kk, ftrue) * load(SMatrix, B, kk, nn, ftrue)
    end
    if rk>0
        kk = tk*k .+ FixedOneTo(rk)
        X += load(SMatrix, A, mm, kk, ftrue) * load(SMatrix, B, kk, nn, ftrue)
    end
    store!(C, mm, nn, X, ftrue)
    return nothing
end

# @inline function mymul!(C::AbstractMatrix, A::AbstractMatrix, B::AbstractMatrix,
#         beta::Number, inbounds::FixedOrBool,
#         mm::AbstractUnitRange{<:Integer}, nn::AbstractUnitRange{<:Integer},
#         tk::Integer, rk::Integer, k::Integer, beta::Number, bs::BlockSize...)
#     if !inbounds
#         checkmulbounds(inbounds, A, B, C, mm, nn, Base.OneTo(tk*k+rk))
#     end
#     kk = FixedOneTo(k)
#     if tk>0
#         submatmul!(C, A, B, beta, ftrue, mm, nn, kk, bs...)
#     end
#     for h=1:tk-1
#         kk = h*k .+ FixedOneTo(k)
#         submatmul!(C, A, B, Fixed(1), ftrue, mm, nn, kk, bs...)
#     end
#     if rk>0
#         kk = tk*k .+ FixedOneTo(rk)
#         submatmul!(C, A, B, Fixed(1), ftrue, mm, nn, kk, bs...)
#     end
#     return nothing
# end

# Fast, zero-size LinearIndices for Static matrices if we define:
Base.axes(A::StaticArray) = map(FixedOneTo, size(A))

"Read a subset of a matrix into a StaticMatrix"
@inline function load!(Y::StaticMatrix{m,n}, C::AbstractMatrix,
         mm::FixedUnitRange{Int,IM,FixedInteger{m}},
         nn::FixedUnitRange{Int,IN,FixedInteger{n}},
         inbounds::FixedOrBool) where {IM,IN,m,n}
     if !inbounds
          checkbounds(C, mm, nn)
     end
     for j in eachindex nn
         for i in eachindex mm
             @inbounds Y[i,j] = X[mm[i],nn[j]]
         end
     end
end

# @generated function load(::Type{T}, C::AbstractMatrix,
#         mm::FixedUnitRange{Int,IM,FixedInteger{m}},
#         nn::FixedUnitRange{Int,IN,FixedInteger{n}},
#         inbounds::FixedOrBool) where {T,IM,IN,m,n}
#     a = Vector{Expr}()
#     for j=1:n
#         for i=1:m
#             push!(a, :( C[k+L[$i,$j]] ))
#         end
#     end
#     return quote
#         Base.@_inline_meta
#         if !inbounds
#              checkbounds(C, mm, nn)
#         end
#         L = LinearIndices(C)
#         k = L[first(mm), first(nn)]-1
#         @inbounds T{m,n}($(Expr(:tuple, a...)))
#     end
# end

@generated function load(::Type{T}, C::StaticMatrix{M,N},
        mm::FixedUnitRange{Int,IM,FixedInteger{m}},
        nn::FixedUnitRange{Int,IN,FixedInteger{n}},
        inbounds::FixedOrBool) where {T,M,N,IM,IN,m,n}
    a = Vector{Expr}()
    L = LinearIndices((M,N))
    for j=1:n
        for i=1:m
            push!(a, :( C[k+$(L[i,j])] ))
        end
    end
    return quote
        Base.@_inline_meta
        if !inbounds
             checkbounds(C, mm, nn)
        end
        k = M*zeroth(nn) + zeroth(mm)
        @inbounds T{m,n}($(Expr(:tuple, a...)))
    end
end
# Note, reading into a transpose is slow. Probably best to read first,
# then transpose.

"Store a small StaticMatrix into a subset of a StaticMatrix"
@inline function store!(C::AbstractMatrix, Y::StaticMatrix{m,n},
         mm::FixedUnitRange{Int,IM,FixedInteger{m}},
         nn::FixedUnitRange{Int,IN,FixedInteger{n}},
         inbounds::FixedOrBool) where {IM,IN,m,n}
     if !inbounds
          checkbounds(C, mm, nn)
     end
     for j in eachindex nn
         for i in eachindex mm
             @inbounds Y[i,j] = X[mm[i],nn[j]]
         end
     end
end

# @generated function store!(C::AbstractMatrix,
#         mm::FixedUnitRange{Int,IM,FixedInteger{m}},
#         nn::FixedUnitRange{Int,IN,FixedInteger{n}},
#         X::StaticMatrix{m,n}, inbounds::FixedOrBool) where {IM,IN,m,n}
#     a = Vector{Expr}()
#     y = Vector{Expr}()
#     Ly = LinearIndices((m,n))
#     for j=1:n
#         for i=1:m
#             push!(a, :( C[k+L[$i,$j]] ))
#             push!(y, :( X[$(Ly[i,j])] ))
#         end
#     end
#     return quote
#         Base.@_inline_meta
#         if !inbounds
#              checkbounds(C, mm, nn)
#         end
#         L = LinearIndices(C)
#         k = L[first(mm), first(nn)]-1
#         @inbounds $(Expr(:tuple, a...)) = $(Expr(:tuple, y...))
#         nothing
#     end
# end

# Faster method, when C is a fixed size.
@generated function store!(C::StaticMatrix{M,N},
        mm::FixedUnitRange{Int,IM,FixedInteger{m}},
        nn::FixedUnitRange{Int,IN,FixedInteger{n}},
        X::StaticMatrix{m,n}, inbounds::FixedOrBool) where {M,N,IM,IN,m,n}
    a = Vector{Expr}()
    y = Vector{Expr}()
    L = LinearIndices((M,N))
    Ly = LinearIndices((m,n))
    for j=1:n
        for i=1:m
            push!(a, :( C[k+$(L[i,j])] ))
            push!(y, :( X[$(Ly[i,j])] ))
        end
    end
    return quote
        Base.@_inline_meta
        if !inbounds
             checkbounds(C, mm, nn)
        end
        k = M*zeroth(nn) + zeroth(mm)
        @inbounds $(Expr(:tuple, a...)) = $(Expr(:tuple, y...))
        nothing
    end
end

# MMatrix from Matrix
# Actually, not faster than existing?
@inline function MMatrix{M,N,T}(C::Matrix{T}) where {M,N,T}
    @boundscheck length(C) == M*N
    X = MMatrix{M,N,T}(undef)
    for i=FixedOneTo(M*N)
        @inbounds X[i] = C[i]
    end
    return X
end
@inline MMatrix{M,N}(C::Matrix{T}) where {M,N,T} = MMatrix{M,N,T}(C)

# TODO Transpose and Adjoint
#load(T::Type, A::Transpose, mm::FixedUnitRange, nn::FixedUnitRange) =
#   transpose(load(T, parent(A), nn, mm))
#store!(A::Transpose, mm::FixedUnitRange, nn::FixedUnitRange, Y::StaticMatrix) =
#   store!(T, parent(A), nn, mm, transpose(Y))


end # module

using FixedNumbers
using StaticArrays
using LinearAlgebra
using BenchmarkTools

m=17
n=18
k=19

A = randn(m,k)
B = randn(k,n)
C = zeros(m,n)
#A = randn(MMatrix{m,k})
#B = randn(MMatrix{k,n})
#C = zeros(MMatrix{m,n})

MA = MMatrix{16,16}(randn(16,16))
MB = MMatrix{16,16}(randn(16,16))
MC = MMatrix{16,16}(zeros(16,16))

MatMatMulExample.mymul!(C, A, B,
    MatMatMulExample.BlockSize(Fixed(4), Fixed(4), Fixed(4), Fixed(true)))

println("Relative inaccuracy compared to BLAS = ", maximum(abs.(C .-  Float64.(big.(A)*big.(B)))) / maximum(abs.(A*B .-  Float64.(big.(A)*big.(B)))))

display(@benchmark MatMatMulExample.mymul!($C, $A, $B,
    $(MatMatMulExample.BlockSize(Fixed(4), Fixed(4), Fixed(2), Fixed(true)))))

display(@benchmark MatMatMulExample.mymul!($MC, $MA, $MB,
    $(MatMatMulExample.BlockSize(Fixed(4), Fixed(4), Fixed(2), Fixed(true)))))
