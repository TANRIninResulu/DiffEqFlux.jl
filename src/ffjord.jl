abstract type CNFLayer <: LuxCore.AbstractExplicitContainerLayer{(:model,)} end

"""
    FFJORD(model, tspan, input_dims, args...; ad = AutoForwardDiff(),
        basedist = nothing, kwargs...)

Constructs a continuous-time recurrent neural network, also known as a neural
ordinary differential equation (neural ODE), with fast gradient calculation
via adjoints [1] and specialized for density estimation based on continuous
normalizing flows (CNF) [2] with a stochastic approach [2] for the computation of the trace
of the dynamics' jacobian. At a high level this corresponds to the following steps:

1. Parameterize the variable of interest x(t) as a function f(z, θ, t) of a base variable z(t) with known density p\\_z.
2. Use the transformation of variables formula to predict the density p\\_x as a function of the density p\\_z and the trace of the Jacobian of f.
3. Choose the parameter θ to minimize a loss function of p\\_x (usually the negative likelihood of the data).

After these steps one may use the NN model and the learned θ to predict the density p\\_x for new values of x.

Arguments:
- `model`: A `Flux.Chain` or `Lux.AbstractExplicitLayer` neural network that defines the dynamics of the model.
- `basedist`: Distribution of the base variable. Set to the unit normal by default.
- `input_dims`: Input Dimensions of the model.
- `tspan`: The timespan to be solved on.
- `args`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/DiffEqDocs/stable/basics/common_solver_opts/)
  documentation for more details.
- `ad`: The automatic differentiation method to use for the internal jacobian trace. Defaults to `AutoForwardDiff()`.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://docs.sciml.ai/DiffEqDocs/stable/basics/common_solver_opts/)
  documentation for more details.

References:

[1] Pontryagin, Lev Semenovich. Mathematical theory of optimal processes. CRC press, 1987.

[2] Chen, Ricky TQ, Yulia Rubanova, Jesse Bettencourt, and David Duvenaud. "Neural ordinary differential equations." In Proceedings of the 32nd International Conference on Neural Information Processing Systems, pp. 6572-6583. 2018.

[3] Grathwohl, Will, Ricky TQ Chen, Jesse Bettencourt, Ilya Sutskever, and David Duvenaud. "Ffjord: Free-form continuous dynamics for scalable reversible generative models." arXiv preprint arXiv:1810.01367 (2018).

"""
@concrete struct FFJORD{M <: AbstractExplicitLayer, D <: Union{Nothing, Distribution}} <:
                 CNFLayer
    model::M
    basedist::D
    ad
    input_dims
    tspan
    args
    kwargs
end

function LuxCore.initialstates(rng::AbstractRNG, n::FFJORD)
    return (;
        model = LuxCore.initialstates(rng, n.model), regularize = false, monte_carlo = true)
end

function FFJORD(model, tspan, input_dims, args...; ad = AutoForwardDiff(),
        basedist = nothing, kwargs...)
    !(model isa AbstractExplicitLayer) && (model = Lux.transform(model))
    return FFJORD(model, basedist, ad, input_dims, tspan, args, kwargs)
end

function __jacobian_with_ps(model, psax, N, x)
    function __jacobian_closure(psx)
        x_ = reshape(psx[1:N], size(x))
        ps = ComponentArray(psx[(N + 1):end], psax)
        return vec(model(x_, ps))
    end
end

function __jacobian(::AutoForwardDiff{nothing}, model, x::AbstractMatrix,
        ps::ComponentArray)
    psd = getdata(ps)
    psx = vcat(vec(x), psd)
    N = length(x)
    J = ForwardDiff.jacobian(__jacobian_with_ps(model, getaxes(ps), N, x), psx)
    return reshape(view(J, :, 1:N), :, size(x, 1), size(x, 2))
end

function __jacobian(::AutoForwardDiff{CS}, model, x::AbstractMatrix, ps) where {CS}
    chunksize = CS === nothing ? ForwardDiff.pickchunksize(length(x)) : CS
    __f = Base.Fix2(model, ps)
    cfg = ForwardDiff.JacobianConfig(__f, x, ForwardDiff.Chunk{chunksize}())
    return reshape(ForwardDiff.jacobian(__f, x, cfg), :, size(x, 1), size(x, 2))
end

function __jacobian(::AutoZygote, model, x::AbstractMatrix, ps)
    y, pb_f = Zygote.pullback(vec ∘ model, x, ps)
    z = ChainRulesCore.@ignore_derivatives fill!(similar(y), __one(y))
    J = Zygote.Buffer(x, size(y, 1), size(x, 1), size(x, 2))
    for i in 1:size(y, 1)
        ChainRulesCore.@ignore_derivatives z[i, :] .= __one(x)
        J[i, :, :] = pb_f(z)[1]
        ChainRulesCore.@ignore_derivatives z[i, :] .= __zero(x)
    end
    return copy(J)
end

__one(::T) where {T <: Real} = one(T)
__one(x::T) where {T <: AbstractArray} = __one(first(x))
__one(::Tracker.TrackedReal{T}) where {T <: Real} = one(T)

__zero(::T) where {T <: Real} = zero(T)
__zero(x::T) where {T <: AbstractArray} = __zero(first(x))
__zero(::Tracker.TrackedReal{T}) where {T <: Real} = zero(T)

function _jacobian(ad, model, x, ps)
    if ndims(x) == 1
        x_ = reshape(x, :, 1)
    elseif ndims(x) > 2
        x_ = reshape(x, :, size(x, ndims(x)))
    else
        x_ = x
    end
    return __jacobian(ad, model, x_, ps)
end

# This implementation constructs the final trace vector on the correct device
function __trace_batched(x::AbstractArray{T, 3}) where {T}
    __diag(x) = reshape(@view(x[diagind(x)]), :, 1)
    return sum(reduce(hcat, __diag.(eachslice(x; dims = 3))); dims = 1)
end

__norm_batched(x) = sqrt.(sum(abs2, x; dims = 1:(ndims(x) - 1)))

function __ffjord(model, u, p, ad = AutoForwardDiff(), regularize::Bool = false,
        monte_carlo::Bool = true)
    N = ndims(u)
    L = size(u, N - 1)
    z = selectdim(u, N - 1, 1:(L - ifelse(regularize, 3, 1)))
    if monte_carlo
        mz, pb_f = Zygote.pullback(model, z, p)
        e = CRC.@ignore_derivatives randn!(similar(mz))
        eJ = first(pb_f(e))
        trace_jac = sum(eJ .* e; dims = 1:(N - 1))
    else
        mz = model(z, p)
        J = _jacobian(ad, model, z, p)
        trace_jac = __trace_batched(J)
        e = CRC.@ignore_derivatives randn!(similar(mz))
        eJ = vec(e)' * reshape(J, size(J, 1), :)
    end
    if regularize
        return cat(mz, -trace_jac, sum(abs2, mz; dims = 1:(N - 1)), __norm_batched(eJ);
            dims = Val(N - 1))
    else
        return cat(mz, -trace_jac; dims = Val(N - 1))
    end
end

(n::FFJORD)(x, ps, st) = __forward_ffjord(n, x, ps, st)

function __forward_ffjord(n::FFJORD, x, ps, st)
    N, S, T = ndims(x), size(x), eltype(x)
    (; regularize, monte_carlo) = st
    sensealg = InterpolatingAdjoint(; autojacvec = ZygoteVJP())

    model = StatefulLuxLayer(n.model, nothing, st.model)

    ffjord(u, p, t) = __ffjord(model, u, p, n.ad, regularize, monte_carlo)

    _z = ChainRulesCore.@ignore_derivatives fill!(similar(x,
            S[1:(N - 2)]..., ifelse(regularize, 3, 1), S[N]), zero(T))

    prob = ODEProblem{false}(ffjord, cat(x, _z; dims = Val(N - 1)), n.tspan, ps)
    sol = solve(prob, n.args...; sensealg, n.kwargs..., save_everystep = false,
        save_start = false, save_end = true)
    pred = __get_pred(sol)
    L = size(pred, N - 1)

    z = selectdim(pred, N - 1, 1:(L - ifelse(regularize, 3, 1)))
    i₁ = L - ifelse(regularize, 2, 0)
    delta_logp = selectdim(pred, N - 1, i₁:i₁)
    if regularize
        λ₁ = selectdim(pred, N, (L - 1):(L - 1))
        λ₂ = selectdim(pred, N, L:L)
    else
        # For Type Stability
        λ₁ = λ₂ = delta_logp
    end

    if n.basedist === nothing
        logpz = -sum(abs2, z; dims = 1:(N - 1)) / T(2) .-
                T(prod(S[1:(N - 1)]) / 2 * log(2π))
    else
        logpz = logpdf(n.basedist, z)
    end
    logpx = reshape(logpz, 1, S[N]) .- delta_logp

    return (logpx, λ₁, λ₂), (; model = model.st, regularize, monte_carlo)
end

__get_pred(sol::ODESolution) = last(sol.u)
__get_pred(sol::AbstractArray{T, N}) where {T, N} = selectdim(sol, N, size(sol, N))

function __backward_ffjord(::Type{T1}, n::FFJORD, n_samples::Int, ps, st, rng) where {T1}
    px = n.basedist

    if px === nothing
        if rng === nothing
            x = randn(T1, (n.input_dims..., n_samples))
        else
            x = randn(rng, T1, (n.input_dims..., n_samples))
        end
    else
        if rng === nothing
            x = rand(px, n_samples)
        else
            x = rand(rng, px, n_samples)
        end
    end

    N, S, T = ndims(x), size(x), eltype(x)
    (; regularize, monte_carlo) = st
    sensealg = InterpolatingAdjoint(; autojacvec = ZygoteVJP())

    model = StatefulLuxLayer(n.model, nothing, st.model)

    ffjord(u, p, t) = __ffjord(model, u, p, n.ad, regularize, monte_carlo)

    _z = ChainRulesCore.@ignore_derivatives fill!(similar(x,
            S[1:(N - 2)]..., ifelse(regularize, 3, 1), S[N]), zero(T))

    prob = ODEProblem{false}(ffjord, cat(x, _z; dims = Val(N - 1)), reverse(n.tspan), ps)
    sol = solve(prob, n.args...; sensealg, n.kwargs..., save_everystep = false,
        save_start = false, save_end = true)
    pred = __get_pred(sol)
    L = size(pred, N - 1)

    return selectdim(pred, N - 1, 1:(L - ifelse(regularize, 3, 1)))
end

"""
FFJORD can be used as a distribution to generate new samples by `rand` or estimate densities
by `pdf` or `logpdf` (from `Distributions.jl`).

Arguments:

- `model`: A FFJORD instance.
- `regularize`: Whether we use regularization (default: `false`).
- `monte_carlo`: Whether we use monte carlo (default: `true`).
"""
@concrete struct FFJORDDistribution{F <: FFJORD} <: ContinuousMultivariateDistribution
    model::F
    ps
    st
end

Base.length(d::FFJORDDistribution) = prod(d.model.input_dims)
Base.eltype(d::FFJORDDistribution) = __eltype(d.ps)

__eltype(ps::ComponentArray) = __eltype(getdata(ps))
__eltype(x::AbstractArray) = eltype(x)
function __eltype(x::NamedTuple)
    T = Ref(Bool)
    fmap(x) do x_
        T[] = promote_type(T[], __eltype(x_))
        x_
    end
    return T[]
end

function Distributions._logpdf(d::FFJORDDistribution, x::AbstractVector)
    return first(first(__forward_ffjord(d.model, reshape(x, :, 1), d.ps, d.st)))
end
function Distributions._logpdf(d::FFJORDDistribution, x::AbstractArray)
    return first(first(__forward_ffjord(d.model, x, d.ps, d.st)))
end
function Distributions._rand!(rng::AbstractRNG, d::FFJORDDistribution,
        x::AbstractArray{<:Real})
    x[:] = __backward_ffjord(eltype(d), d.model, size(x, ndims(x)), d.ps, d.st, rng)
    return x
end
