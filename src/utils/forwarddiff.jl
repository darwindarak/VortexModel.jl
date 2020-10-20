
using ForwardDiff
using DiffRules

import ForwardDiff: Dual, Partials, single_seed, partials, Chunk, Tag, seed!, value,
              gradient, valtype, extract_gradient!, derivative,extract_derivative

const AMBIGUOUS_TYPES = (AbstractFloat, Irrational, Integer, Rational,
                         Real, RoundingMode, ComplexF64)

# The philosophy followed here is a bit different from that used by
# ForwardDiff. Here, the number of partials is limited to 1 or 2, even for
# arrays of vortex elements. For ComplexComplex cases, there are two partials,
# corresponding to differentiation with respect to the real and imaginary parts
# of the differentiation variable. For ComplexReal cases, there is one partial, since the
# differentiation variable is real.
# ComplexComplexDual is designated for derivatives of complex functions
# with respect to complex numbers
# ComplexRealDual is for derivatives of complex functions with respect to
# real numbers
# ComplexDual encompasses all complex dual types
const ComplexDual{T,V,N} = Complex{Dual{T,V,N}}
#const ComplexComplexDual{T,V} = ComplexDual{T,V,2}
#const ComplexRealDual{T,V} = ComplexDual{T,V,1}
#const RealComplexDual{T,V} = Dual{T,V,2}

# Constructor for ComplexDual based on real Partials for dreal and dimag
@inline function ComplexDual{T}(z::Number,dr::Partials{N,V},di::Partials{N,V}) where {T,N,V<:Real}
    zr, zi = reim(z)
    return Dual{T}(zr,dr) + im*Dual{T}(zi,di)
end

# Constructor for ComplexDual based on complex Partials for dz and dz*
@inline function ComplexDual{T}(z::Number,dz::Partials{N,V},dzstar::Partials{N,V}) where {T,N,V<:Complex}
    dr, di = reim_partials(dz,dzstar)
    return ComplexDual{T}(z,dr,di)
end

@inline ComplexDual{T}(z::Number,dz::Complex,dzstar::Complex) where {T} =
    ComplexDual{T}(z,Partials(tuple(dz)),Partials(tuple(dzstar)))

@inline Base.one(::Type{<:ComplexDual{T}},z::Number) where T = ComplexDual{T}(z,one(z),zero(z))


@inline valtype(::ComplexDual{T,V,N}) where {T,V,N} = V
@inline valtype(::Type{ComplexDual{T,V,N}}) where {T,V,N} = V


# ==== extensions of Partials ==== #
@inline Base.conj(v::Partials{N,V}) where {N,V} = Partials{N,V}(conj.(v.values))
@inline Base.real(v::Partials{N,Complex{V}}) where {N,V} = Partials{N,V}(real.(v.values))
@inline Base.imag(v::Partials{N,Complex{V}}) where {N,V} = Partials{N,V}(imag.(v.values))

@inline Base.:*(x::Complex, partials::Partials) = partials*x

@inline function Base.:*(partials::Partials, x::Complex)
        return Partials(ForwardDiff.scale_tuple(partials.values, x))
end

# extract the partial derivatives from a complex dual number
@inline function ForwardDiff.partials(d::ComplexDual)
    dr, di = reim(d)
    return partials(dr), partials(di)
end


# assemble the derivatives d/dz and d/dz* from the partials
@inline function _derivs(dvrx,dvry,dvix,dviy)
    return 0.5*(dvrx+dviy) + 0.5*im*(dvix-dvry), 0.5*(dvrx-dviy) + 0.5*im*(dvix+dvry)
end

# Given a complex dual number, extract Partials of dz and dz*
@inline function dz_partials(d::ComplexDual{T,V,N}) where {T,V,N}
    dr, di = partials(d)
    tmp  = [_derivs(dr[i], dr[i+1], di[i],di[i+1]) for i in 1:2:N]
    return Partials(tuple(first.(tmp)...)), Partials(tuple(last.(tmp)...))
end

@inline Base.@propagate_inbounds function dz_partials(d::ComplexDual, i)
    dr, di = partials(d)
    return _derivs(dr[2i-1], dr[2i], di[2i-1],di[2i])
end

@inline Base.@propagate_inbounds dz_partials(::Type{T}, d::ComplexDual{T}, i...) where T = dz_partials(d, i...)



# Given a complex dual, return dz and dzstar as Partial types. Ugly way of doing
# this
@inline function extract_gradient!(dz,dzstar,d::ComplexDual{T,V,N}) where {T,V,N}
    tmp, tmpstar = dz_partials(d)
    dz .= tmp
    dzstar .= tmpstar
    return dz,dzstar
end

# This is for making sure that the desired gradient has the same tag as the dual
@inline extract_gradient!(::Type{T},dz,dzstar,d::ComplexDual{T,V,N}) where {T,V,N} =
          extract_gradient!(dz,dzstar,d)


"""
    ForwardDiff.extract_derivative(T,d::ComplexDual)

Given a complex dual value `d` and tag `T`, extract the derivatives d/dz
and d/dz* from the partials in `d`.
"""
@inline function extract_derivative(::Type{T},d::ComplexDual{T}) where T
   return dz_partials(d,1)
end

# If the function outputs a tuple of duals, as would be the case for
# nested derivatives, then we deal with each one by one and assemble an overall
# list of derivatives
@inline function extract_derivative(::Type{T},dlist::NTuple{N,ComplexDual{T}}) where {N,T}
   out = ()
   for d in dlist
        out = (out...,extract_derivative(T,d)...)
    end
    out
end

# Given complex Partials for d/dz and d/dz*, return partials for dr/dx,y and di/dx,y
@inline function reim_partials(dz::Partials{N,V},dzstar::Partials{N,V}) where {T,V<:Complex,N}
    drx, dix = reim(dz+dzstar)
    dry, diy = reim(im*dz-im*dzstar)
    return _splice_xy(drx,dry), _splice_xy(dix,diy)
end

# Given partials for the Create separate partials for the real part and the imaginary part.
# These are organized as drx[1],dry[1],drx[2],dry[2],... and dix[1],diy[1],dix[2],diy[2],...
@inline function _splice_xy(dx::Partials{N},dy::Partials{N}) where {N}
    return Partials(tuple([ifelse(mod(i,2) == 0,dy[max(i÷2,1)],dx[(i+1)÷2]) for i in 1:2N]...))
end

# Return the value of a complex dual
@inline function value(d::ComplexDual)
    dr, di = reim(d)
    return value(dr)+im*value(di)
end

@generated function construct_complex_seeds(::Type{Partials{N,V}}) where {N,V}
    return Expr(:tuple, Expr(:tuple,[:(single_seed(Partials{N,V}, Val{2*$i-1}())) for i in 1:N÷2]...),
                        Expr(:tuple,[:(single_seed(Partials{N,V}, Val{2*$i-0}())) for i in 1:N÷2]...))
end

function seed!(duals::AbstractArray{<:ComplexDual{T,V,M}}, x,
               rseeds::NTuple{N,Partials{M,V}},iseeds::NTuple{N,Partials{M,V}}) where {T,V,N,M}
    for i in 1:N
        #duals[i] = Dual{T,V,M}(real(x[i]), rseeds[i]) + im*Dual{T,V,M}(imag(x[i]), iseeds[i])
        duals[i] = ComplexDual{T,V,M}(x[i],rseeds[i],iseeds[i])
    end
    return duals
end

function seed!(duals::AbstractArray{<:ComplexDual{T,V,M}}, x,
               rseed::Partials{M,V} = zero(Partials{M,V}),iseed::Partials{M,V} = zero(Partials{M,V})) where {T,V,N,M}
    for i in eachindex(duals)
        duals[i] = ComplexDual{T,V,M}(x[i],rseed,iseed)
    end
    return duals
end

function dualize(::Type{T},x::AbstractArray{<:Complex{V}}) where {T,V}
    xdual = similar(x,ComplexDual{T,V,2*length(v)})
    seed!(xdual,x)
end

# =====  Configurations =====  #
struct ComplexGradientConfig{T,V,N,D,M} <: ForwardDiff.AbstractConfig{N}
    rseeds::NTuple{N,Partials{M,V}}
    iseeds::NTuple{N,Partials{M,V}}
    duals::D
end
function ComplexGradientConfig(f::F,
                        x::AbstractArray{Complex{V}},
                        ::Chunk{N} = Chunk(x),
                        ::T = Tag(f, V)) where {F,V,N,T}
    rseeds, iseeds = construct_complex_seeds(ForwardDiff.Partials{2N,V})
    duals = similar(x, ComplexDual{T,V,2N})
    return ComplexGradientConfig{T,V,N,typeof(duals),2N}(rseeds, iseeds, duals)
end

# ===== gradient ===== #

# Given a function f of z and a complex array z, evaluate the gradient wrt z at z
function gradient(f, z::AbstractArray{Complex{V}},
            cfg::ComplexGradientConfig{T} = ComplexGradientConfig(f, z)) where {T, V}
    # Should put the checking back in.
    #CHK && checktag(T, f, z)
    checktag(T, f, z)
    ForwardDiff.vector_mode_gradient(f, z, cfg)
end

function ForwardDiff.vector_mode_gradient(f::F, z, cfg::ComplexGradientConfig{T}) where {T, F}
    ydual = ForwardDiff.vector_mode_dual_eval(f, z, cfg)
    dz = similar(z, Complex{valtype(ydual)})
    dzstar = similar(z, Complex{valtype(ydual)})
    return extract_gradient!(T, dz, dzstar,ydual)
end

function ForwardDiff.vector_mode_dual_eval(f::F, z, cfg::ComplexGradientConfig) where {F}
    zduals = cfg.duals
    seed!(zduals,z,cfg.rseeds,cfg.iseeds)
    return f(zduals)
end

# ===== derivative ===== #


"""
    ForwardDiff.derivative(f,z::Complex)

Compute the derivative of function `f` with respect to `z` and `conj(z)`
"""
@inline function derivative(f::F, z::C) where {F,C<:Complex}
    T = typeof(ForwardDiff.Tag(f, C))
    # making f output complex ensures that it gets dispatched to our extract_derivative
    # for complex Duals rather than the native one in ForwardDiff
    return extract_derivative(T,complex.(f(one(ComplexDual{T},z))))
end




# preempt other function diffrules. The two entries correspond to d/dz and d/dz*
DiffRules.@define_diffrule Base.abs2(z) = :(conj($z)), :($z)
#DiffRules.@define_diffrule Base.conj(z) = :(0), :(1)
#DiffRules.@define_diffrule Base.real(z) = :(0.5), :(0.5)
#DiffRules.@define_diffrule Base.imag(z) = :(0.5im), :(-0.5im)

DiffRules.@define_diffrule Base.sqrt(z) = :(inv(2 * sqrt($z))), :(0)
DiffRules.@define_diffrule Base.log(z) = :(inv($z)), :(0)
DiffRules.@define_diffrule Base.:^(z,p) = :($p * ($z^($p - 1))), :(0)

DiffRules.@define_diffrule Base.abs(z) = :(0.5*conj($z)*inv(abs($z))), :(0.5*$z*inv(abs($z)))

# Extend functions of a single complex argument to accept dual argument
macro extend_unary_dual_to_complex(fcn)
    M = :Base
    f = :($fcn)
    dfz, dfzstar = DiffRules.diffrule(M,f,:v)
    fdef = quote
        function $M.$f(z::ComplexDual{T}) where {T}
            v = value(z)
            dvz, dvzstar = dz_partials(z)

            # chain rule
            dfdz =     $dfz*dvz     + $dfzstar*conj(dvzstar)
            dfdzstar = $dfz*dvzstar + $dfzstar*conj(dvz)

            return ComplexDual{T}($M.$f(v),dfdz,dfdzstar)
        end
        #=
        function $M.$f(z::ComplexRealDual{T}) where {T}
            v = value(z)
            dv = extract_derivative(T,z)

            # chain rule
            df =     $dfz*dv     + $dfzstar*conj(dv)

            return ComplexRealDual{T}($M.$f(v),df)

        end
        =#
    end
    return esc(fdef)
end


# Extend functions of a single complex argument and another (non-dual) argument to accept
# dual argument in place of first argument
macro extend_binary_dual_to_complex(fcn)
    M = :Base
    f = :($fcn)
    dfz, dfzstar = DiffRules.diffrule(M,f,:v,:p)
    defs = quote end
    for R in AMBIGUOUS_TYPES
        expr = quote
            function $M.$f(z::ComplexDual{T},p::$R) where {T}
                v = value(z)
                dvz, dvzstar = dz_partials(z)

                # chain rule
                dfdz =     $dfz*dvz     + $dfzstar*conj(dvzstar)
                dfdzstar = $dfz*dvzstar + $dfzstar*conj(dvz)

                return ComplexDual{T}($M.$f(v,p),dfdz,dfdzstar)

            end
            #=
            function $M.$f(z::ComplexRealDual{T},p::$R) where {T}
                v = value(z)
                dv = extract_derivative(T,z)

                # chain rule
                df =     $dfz*dv     + $dfzstar*conj(dv)

                return ComplexRealDual{T}($M.$f(v,p),df)

            end
            =#
        end
        append!(defs.args, expr.args)
    end
    return esc(defs)
end


#@extend_unary_dual_to_complex conj
#@extend_unary_dual_to_complex real
#@extend_unary_dual_to_complex imag

@extend_unary_dual_to_complex abs2
@extend_unary_dual_to_complex sqrt
@extend_unary_dual_to_complex log
@extend_unary_dual_to_complex abs

@extend_binary_dual_to_complex ^




# ===== Old stuff below here ===== #

#=


@inline function ComplexComplexDual{T}(z::Number,dz::Number,dzstar::Number) where {T}
  zr, zi = reim(z)
  drdx, didx = _dx_derivs(complex(dz),complex(dzstar))
  drdy, didy = _dy_derivs(complex(dz),complex(dzstar))
  return Dual{T}(zr,ForwardDiff.Partials((drdx,drdy))) +
      im*Dual{T}(zi,ForwardDiff.Partials((didx,didy)))
end

@inline ComplexComplexDual{T}(z::AbstractArray{S},dz::AbstractArray{S},dzstar::AbstractArray{S}) where {T,S<:Number} =
      map((u, v, w) -> ComplexComplexDual{T}(u,v,w),z,dz,dzstar)

@inline function ComplexRealDual{T}(z::Number,dz::Number) where {T}
  zr, zi = reim(z)
  dr, di = reim(dz)
  return Dual{T}(zr,dr) + im*Dual{T}(zi,di)
end

@inline ComplexRealDual{T}(z::AbstractArray{S},dz::AbstractArray{S}) where {T,S<:Number} =
      map((u, v) -> ComplexRealDual{T}(u,v),z,dz)

@inline ComplexComplexDual{T}() where {T} = ComplexComplexDual{T}(0.0,0.0,0.0)
@inline ComplexComplexDual{T}(z) where {T} = ComplexComplexDual{T}(z,0.0,0.0)
@inline ComplexComplexDual(args...) = ComplexComplexDual{Nothing}(args...)

@inline ComplexRealDual{T}() where {T} = ComplexRealDual{T}(0.0,0.0)
@inline ComplexRealDual{T}(z) where {T} = ComplexRealDual{T}(z,0.0)
@inline ComplexRealDual(args...) = ComplexRealDual{Nothing}(args...)

@inline Base.one(::Type{<:ComplexComplexDual{T}},z::Number) where T = ComplexComplexDual{T}(z,one(z),zero(z))
@inline Base.one(::Type{<:ComplexRealDual{T}},z::Number) where T = ComplexRealDual{T}(z,one(z))
@inline Base.one(::Type{<:Dual{T}},z::Number) where T = Dual{T}(z,one(z))


@inline function _derivs(dvr::ForwardDiff.Partials{2},dvi::ForwardDiff.Partials{2})
    dvrx, dvry = dvr
    dvix, dviy = dvi
    return 0.5*(dvrx+dviy) + 0.5*im*(dvix-dvry), 0.5*(dvrx-dviy) + 0.5*im*(dvix+dvry)
end

# assemble the derivative from the partials
@inline function _derivs(dvr::ForwardDiff.Partials{1},dvi::ForwardDiff.Partials{1})
    return dvr[1] + im*dvi[1]
end


# get the d/dx derivatives from d/dz and d/dz*
@inline _dx_derivs(dvz::Complex{T},dvzstar::Complex{T}) where {T} = reim(   dvz +    dvzstar)

# get the d/dy derivatives from d/dz and d/dz*
@inline _dy_derivs(dvz::Complex{T},dvzstar::Complex{T}) where {T} = reim(im*dvz - im*dvzstar)






"""
    dualize(T::Tag,v::S,::Type{Number})

Return a Dual (if the last argument is real) or complex Dual (if last argument is
complex) form of `v`.
"""
@inline dualize(::Type{T},v::Complex{S},::Type{R}) where {T, S<:Real,R<:Complex} = convert(ComplexComplexDual{T,S},v)
@inline dualize(::Type{T},v::Complex{S},::Type{R}) where {T, S<:Real,R<:Real} = convert(ComplexRealDual{T,S},v)
@inline dualize(::Type{T},v::S,::Type{R}) where {T, S<:Real,R<:Real} = convert(Dual{T,S,1},v)
@inline dualize(::Type{T},v::S,::Type{R}) where {T, S<:Real,R<:Complex} = dualize(T,complex(v),R)

#@inline dualize(::Type{T},v::Complex{S}) where {T, S<:Real} = convert(ComplexComplexDual{T,S},v)
#@inline dualize(::Type{T},v::S) where {T, S<:Real} = convert(Dual{T,S,1},v)

"""
    seed(T,v::Vector{S},R::Type{Number},i::Int)

Return a Dual (if R is real) or complex (if R is complex) Dual form of vector `v`,
with the partials of the `i`th component of the vector set to unit
values (i.e., to `1` or to `1, 0`, respectively).
"""
function seed(::Type{T},v::Vector{S},::Type{R},i::Int) where {T, S <: Number, R<:Number}
    d = dualize.(T,v,R)
    d[i] = one(eltype(d),v[i])
    return d
end


"""
    ForwardDiff.derivative(f,z::Complex)

Compute the derivative of function `f` with respect to `z` and `conj(z)`
"""
@inline function derivative(f::F, z::C) where {F,C<:Complex}
    T = typeof(ForwardDiff.Tag(f, C))
    # making f output complex ensures that it gets dispatched to our extract_derivative
    # for complex Duals rather than the native one in ForwardDiff
    return extract_derivative(T,complex.(f(one(ComplexComplexDual{T},z))))
end

"""
    ForwardDiff.extract_derivative(T,d::ComplexDual)

Given a complex dual value `d` and tag `T`, extract the derivatives d/dz
and d/dz* from the partials in `d`.
"""
@inline function extract_derivative(::Type{T},d::ComplexDual{T}) where T
   dr, di = reim(d)
   return _derivs(partials(dr),partials(di))
end

# If the function outputs a tuple of duals, as would be the case for
# nested derivatives, then we deal with each one by one and assemble an overall
# list of derivatives
@inline function extract_derivative(::Type{T},dlist::NTuple{N,ComplexDual{T}}) where {N,T}
   out = ()
   for d in dlist
        out = (out...,extract_derivative(T,d)...)
    end
    out
end

# These are meant for array-valued outputs of functions, where each array
# element will be a derivative (or tuple of derivatives d/dz, d/dz*)
@inline extract_derivative(::Type{T},v::AbstractArray{<:ComplexComplexDual{T}}) where {T} =
        (d = map(x -> extract_derivative(T,x), v); return first.(d), last.(d))

@inline extract_derivative(::Type{T},v::AbstractArray{<:ComplexRealDual{T}}) where {T} =
        (d = map(x -> extract_derivative(T,x), v); return d)


=#
