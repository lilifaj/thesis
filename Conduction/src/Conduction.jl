module Conduction

using Base: Real, Float64
using QuadGK, HCubature, Roots, Base.Threads
import Base.Threads.@spawn
include("Variables.jl")
include("Utilities.jl")

# DOS of a doped semiconductor (J^-1.cm^-3)
DOS(semiconductor::Semiconductor, U::Real, T::Real)::Float64 = (semiconductor.Ni / semiconductor.SigmaI(T) * exp(-(U * k * T - semiconductor.ModeEffect)^2 / (2 * semiconductor.SigmaI(T)^2)) + semiconductor.Nd / semiconductor.SigmaD(T) * exp(-(U * k * T - semiconductor.ModeEffect + semiconductor.Ed)^2 / (2 * semiconductor.SigmaD(T)^2))) / sqrt(2 * pi)

DOSp2(semiconductor::Semiconductor, U::Real, T::Real) = 100^3 * (semiconductor.Ni) / semiconductor.SigmaI(T) * exp(-(log(U * k * T) - log(semiconductor.ModeEffect))^2 / (2 * (semiconductor.SigmaI(T) / hbar)^2)) / sqrt(2 * pi)

DOSp(semiconductor::Semiconductor, U::Real, T::Real) = 100^3 * (semiconductor.Ni) / semiconductor.SigmaI(T) * exp(-(U * k * T - semiconductor.ModeEffect)^2 / (2 * semiconductor.SigmaI(T)^2)) / sqrt(2 * pi)

# Fermi-Dirac distribution
F(semiconductor::Semiconductor, U::Real, T::Real)::Float64 = 1 / (1 + exp(U - (semiconductor.ModeEffect + semiconductor.Uf(T)) / (k * T)))

# Number of free state within a sphere of radius R
N(semiconductor::Semiconductor, U::Real, T::Real, R::Real, F::Real)::Float64 = (k * T) / (8 * semiconductor.alpha^3) * 2 * pi * hcubature(
    x -> DOS(semiconductor, var1(U, Conduction.beta(semiconductor, T, F), R, x[1], x[2], x[3]), T) * (1 - Conduction.F(semiconductor, var1(U, Conduction.beta(semiconductor, T, F), R, x[1], x[2], x[3]), T)) * 1 / (1 - x[1])^2 * x[2]^2 * sin(x[3]),
    [0, 0, 0],
    [1, R, pi],
    rtol=1e-5)[1]

# Range to the nearest neighbour using a VRH approach
function RnnVRH(semiconductor::Semiconductor, U::Real, T::Real, F::Real)::Float64
    Rnn(semiconductor, U, T, 1, F)
end

function Rnn(semiconductor::Semiconductor, U::Real, T::Real, x::Real, F::Real)::Float64
    i = 0;
    while i < 100
        try
            return find_zero(r -> N(semiconductor, U, T, r, F) - x, 5 + i * 10, Order0())
            break
        catch
        end

        i += 1;
    end

    throw(ConvergenceError())
end

# Range to the nearest neighbour using a percolation approach
RnnPerco(semiconductor::Semiconductor, U::Real, T::Real)::Float64 = ( (4pi) / (3 * 2.8) * quadgk(
    r -> DOS(semiconductor, r, T) * (1 - Conduction.F(semiconductor, r, T)),
    -Inf,
    U + semiconductor.ModeEffect / (k * T),
    rtol=1e-3
    )[1])^(-1/3) * 2 * semiconductor.alpha * (k * T)^(-1/3)

# Range to the nearest neighbour using a percolation approach taking into account the field
function RnnPercoField(semiconductor::Semiconductor, U::Real, T::Real, F::Real)::Float64
    Rnn(semiconductor, U, T, 2.8, F)
end

# Effective distance of jump of an electron
function xf(semiconductor::Semiconductor, Rnn::Real, U::Real, T::Real, F::Real)
    functionI = [I1, I2, I3, I4]
    resultI = Array{Float64}(undef, 4)

    for i in 1:4
        resultI[i] = functionI[i](U, T, semiconductor, Rnn, F)
    end

    return (resultI[1] + resultI[2]) / (resultI[3] + resultI[4])
end

function xf(semiconductor::Semiconductor, U::Real, T::Real, F::Real)::Float64
    R = Conduction.RnnVRH(semiconductor, U, T, F);

    return xf(semiconductor, R, U, T, F)
end

function electronMobility(semiconductor::Semiconductor, Rnn::Float64, xf::Float64, F::Real)::Float64
    return semiconductor.nu * xf * exp(-Rnn) / (-F * 2 * semiconductor.alpha)
end

function electronMobility(semiconductor::Semiconductor, U, T, F)::Float64
    R = Conduction.RnnVRH(semiconductor, U, T, F);
    xf = Conduction.xf(semiconductor, U, T, F);

    return electronMobility(semiconductor, R, xf, F)
end

function t(semiconductor, Rnn::Float64, U::Real, T::Real, F::Real)::Float64
    functionI = [It1, It2, It3, It4]
    resultI = Array{Float64}(undef, 4)

    for i in 1:4
        resultI[i] = functionI[i](U, T, semiconductor, Rnn, F)
    end

    return (resultI[1] + resultI[2]) / (resultI[3] + resultI[4])
end

function t(semiconductor::Semiconductor, U, T, F)::Float64
    R = Conduction.RnnVRH(semiconductor, U, T, F);
    return t(semiconductor, R, U, T, F)
end

# Electric diffusion (cm^2/s)
function D(semiconductor::Semiconductor, Rnn::Float64, xf::Float64, t::Float64)::Float64
    return 1 / 6 * (2 * xf * Rnn *  semiconductor.nu * exp(-Rnn) * t + Rnn^2) * semiconductor.nu * exp(-Rnn) / (4 * semiconductor.alpha^2)
end

function D(semiconductor::Semiconductor, U::Real, T::Real, F::Real)::Float64
    R = Conduction.RnnVRH(semiconductor, U, T, F);
    xf = Conduction.xf(semiconductor, U, T, F);
    t = Conduction.t(semiconductor, U, T, F);

    return D(semiconductor, R, xf, t)
end

function ein(semiconductor::Semiconductor, Rnn::Float64, xf::Float64, t::Float64, F::Real)::Float64
    return Conduction.D(semiconductor, Rnn, xf, t) / Conduction.electronMobility(semiconductor, Rnn, xf, F)
end

function ein(semiconductor::Semiconductor, U::Real, T::Real, F::Real)
    R = Conduction.RnnVRH(semiconductor, U, T, F);
    xf = Conduction.xf(semiconductor, U, T, F);
    t = Conduction.t(semiconductor, U, T, F);

    return ein(semiconductor, R, xf, t, F)
end

Dp(semiconductor, U, T) = semiconductor.gamma(T)^(-2) * (U * k * T/ hbar)^(-4)

C(U, T)::Float64 = U^2 * k / (exp(U/2) - exp(-U/2))^2

kp(semiconductor, T) = k * T * quadgk(
    r -> DOSp(semiconductor, r, T) * C(r, T) * Dp(semiconductor, r, T),
    semiconductor.omega_min * hbar / (k * T),
    +Inf
)[1]

function ke(semiconductor, T)
    function f(r)
        Rnn = Conduction.RnnVRH(semiconductor, r, T);
        xf = Conduction.xf(semiconductor, Rnn, r, T);
        t = Conduction.t(semiconductor, Rnn, r, T);
        return DOS(semiconductor, r, T) * C(r, t) * D_ter(semiconductor, Rnn, xf, t)
    end
    return k * T * quadgk(
    r -> f(r),
    -15,
    15)[1]
end

function occupiedStates(semiconductor::Semiconductor, U, T)
    return DOS(semiconductor, U, T) * Conduction.F(semiconductor, U, T)
end

function overallDiffusion(semiconductor::Semiconductor, T::Real, F::Real, x_limit::Real)
    return Conduction.overallEinD(semiconductor, Conduction.D, T, F, x_limit)
end

function overallMobility(semiconductor::Semiconductor, U::Real, T::Real, F::Real, x_limit::Real)
    fd(x) = occupiedStates(semiconductor, x, T)
    fn(x) = return occupiedStates(semiconductor, x, T) * electronMobility(semiconductor, U, T, F)

    return average_density(fn_final, fd, x_limit);
end

function overallEinD(semiconductor::Semiconductor, f::Function, T, F::Real, x_limit::Real)
    fd(x) = occupiedStates(semiconductor, x, T);
    fn(x::Real) = occupiedStates(semiconductor, x, T) * f(semiconductor, x, T, F)

    return average_density(fn, fd, x_limit)
end

function overallEin(semiconductor::Semiconductor, T::Real, F::Real,  x_limit::Real)
    return overallEinD(semiconductor, Conduction.ein, T, F, x_limit)
end

end # module