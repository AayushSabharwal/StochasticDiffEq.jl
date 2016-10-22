"""
`solve(prob::SDEProblem,tspan)`

Solves the SDE as defined by prob on the time interval tspan. If not given, tspan defaults to [0,1].

### Keyword Arguments

* `Δt`: Sets the initial stepsize. Defaults to an automatic choice.
* `save_timeseries`: Saves the result at every timeseries_steps steps. Default is true.
* `timeseries_steps`: Denotes how many steps between saving a value for the timeseries. Defaults to 1.
* `adaptive` - Turns on adaptive timestepping for appropriate methods. Default is false.
* `γ` - The risk-factor γ in the q equation for adaptive timestepping. Default is 2.
* `qmax` - Defines the maximum value possible for the adaptive q. Default is 1.125.
* `δ` - The weight-factor in the error estimate. Default is 1/6.
* `ablstol` - Absolute tolerance in adaptive timestepping. Defaults to 1e-3.
* `reltol` - Relative tolerance in adaptive timestepping. Defaults to 1e-6.
* `maxiters` - Maximum number of iterations before stopping. Defaults to 1e9.
* `Δtmax` - Maximum Δt for adaptive timestepping. Defaults to half the timespan.
* `Δtmin` - Minimum Δt for adaptive timestepping. Defaults to 1e-10.
* `internalnorm` - The norm for which error estimates are calculated. Default is 2.
* `progressbar` - Turns on/off the Juno progressbar. Defualt is false.
* `progress_steps` - Numbers of steps between updates of the progress bar. Default is 1000.
* `discard_length` - Size at which to discard future information in adaptive. Default is 1e-15.
* `tableau`: The tableau for an `:SRA` or `:SRI` algorithm. Defaults to SRIW1 or SRA1.
* `adaptivealg`: The adaptive timestepping algorithm. Default is `:RSwm3`.
* `alg`: String which defines the solver algorithm. Defult is "SRIW1Optimized". Possibilities are:

    - `:EM`- The Euler-Maruyama method.
    - `:RKMil` - An explicit Runge-Kutta discretization of the strong Order 1.0 Milstein method.
    - `:SRA` - The strong Order 2.0 methods for additive SDEs due to Rossler. Not yet implemented.
      Default tableau is for SRA1.
    - `:SRI` - The strong Order 1.5 methods for diagonal/scalar SDEs due to Rossler.
      Default tableau is for SRIW1.
    - `:SRIW1Optimized` - An optimized version of SRIW1. Strong Order 1.5.
    - `:SRA1Optimized` - An optimized version of SRIA1. Strong Order 2.0.
    - `:SRAVectorized` - A vectorized implementation of SRA algorithms. Requires 1-dimensional problem.
    - `:SRIVectorized` - A vectorized implementation of SRI algorithms. Requires 1-dimensional problem.
"""
function solve(prob::AbstractSDEProblem,tspan::AbstractArray=[0,1];Δt::Number=0.0,save_timeseries::Bool = true,
              timeseries_steps::Int = 1,alg=nothing,adaptive=false,γ=2.0,alg_hint=nothing,
              abstol=1e-3,reltol=1e-6,qmax=1.125,δ=1/6,maxiters::Int = round(Int,1e9),
              Δtmax=nothing,Δtmin=nothing,progress_steps=1000,internalnorm=2,
              discard_length=1e-15,adaptivealg::Symbol=:RSwM3,progressbar=false,tType=typeof(Δt),tableau = nothing)

  atomloaded = isdefined(Main,:Atom)
  @unpack u₀,knownanalytic,analytic, numvars, sizeu,isinplace,noise = prob
  tspan = vec(tspan)
  if tspan[2]-tspan[1]<0 || length(tspan)>2
    error("tspan must be two numbers and final time must be greater than starting time. Aborting.")
  end

  if adaptive
    warn("SDE adaptivity is currently disabled")
    adaptive = false
  end
  u = copy(u₀)
  if !isinplace && typeof(u)<:AbstractArray
    f = (t,u,du) -> (du[:] = prob.f(t,u))
    g = (t,u,du) -> (du[:] = prob.g(t,u))
  else
    f = prob.f
    g = prob.g
  end

  if alg==nothing
    alg = plan_sde(alg_hint,abstol,reltol,noise.noise_type)
  end

  if adaptive && alg ∈ SDE_ADAPTIVEALGORITHMS
    Δt = 1.0*Δt
    initialize_backend(:DataStructures)
    if adaptivealg == :RSwM3
      initialize_backend(:ResettableStacks)
    end
  end
  tType=typeof(Δt)
  if Δt == 0.0
    if alg==:Euler
      order = 0.5
    elseif alg==:RKMil
      order = 1.0
    else
      order = 1.5
    end
    Δt = sde_determine_initΔt(u₀,float(tspan[1]),abstol,reltol,internalnorm,f,g,order)
  end

  if Δtmax == nothing
    Δtmax = (tspan[2]-tspan[1])/2
  end
  if Δtmin == nothing
    Δtmin = tType(1e-10)
  end


  uType = typeof(u₀)

  T = tType(tspan[2])
  t = tType(tspan[1])

  timeseries = Vector{uType}(0)
  push!(timeseries,u₀)
  ts = Vector{tType}(0)
  push!(ts,t)

  #PreProcess
  if (alg==:SRA || alg==:SRAVectorized) && tableau == nothing
    tableau = constructSRA1()
  elseif tableau == nothing # && (alg==:SRI || alg==:SRIVectorized)
    tableau = constructSRIW1()
  end

  uEltype = eltype(u)
  tType=typeof(Δt)
  uType = typeof(u)
  tableauType = typeof(tableau)

  if numvars == 1
    rands = ChunkedArray(noise.noise_func)
  else
    rands = ChunkedArray(noise.noise_func,map((x)->x/x,u)) # Strip units
  end

  randType = typeof(map((x)->x/x,u)) # Strip units

  if uType <: AbstractArray
    uEltypeNoUnits = eltype(u./u)
  else
    uEltypeNoUnits = typeof(u./u)
  end


  Ws = Vector{randType}(0)
  if numvars == 1
    W = 0.0
    Z = 0.0
    push!(Ws,W)
  else
    W = zeros(sizeu)
    Z = zeros(sizeu)
    push!(Ws,copy(W))
  end
  sqΔt = sqrt(Δt)
  iter = 0
  maxstacksize = 0
  #EEst = 0
  typeof(u) <: Number ? value_type = :Number : value_type = :AbstractArray

  rateType = typeof(u/t) ## Can be different if united

  #@code_warntype sde_solve(SDEIntegrator{alg,typeof(u),eltype(u),ndims(u),ndims(u)+1,typeof(Δt),typeof(tableau)}(f,g,u,t,Δt,T,maxiters,timeseries,Ws,ts,timeseries_steps,save_timeseries,adaptive,adaptivealg,δ,γ,abstol,reltol,qmax,Δtmax,Δtmin,internalnorm,numvars,discard_length,progressbar,atomloaded,progress_steps,rands,sqΔt,W,Z,tableau))

  u,t,W,timeseries,ts,Ws,maxstacksize,maxstacksize2 = sde_solve(SDEIntegrator{alg,uType,uEltype,ndims(u),ndims(u)+1,tType,tableauType,uEltypeNoUnits,randType,rateType}(f,g,u,t,Δt,T,maxiters,timeseries,Ws,ts,timeseries_steps,save_timeseries,adaptive,adaptivealg,δ,γ,abstol,reltol,qmax,Δtmax,Δtmin,internalnorm,numvars,discard_length,progressbar,atomloaded,progress_steps,rands,sqΔt,W,Z,tableau))

  (atomloaded && progressbar) ? Main.Atom.progress(1) : nothing #Use Atom's progressbar if loaded

  if knownanalytic
    u_analytic = analytic(t,u₀,W)
    if save_timeseries
      timeseries_analytic = Vector{uType}(0)
      for i in 1:size(Ws,1)
        push!(timeseries_analytic,analytic(ts[i],u₀,Ws[i]))
      end
      return(SDESolution(u,u_analytic,W=W,timeseries=timeseries,t=ts,Ws=Ws,timeseries_analytic=timeseries_analytic,maxstacksize=maxstacksize))
    else
      return(SDESolution(u,u_analytic,W=W,maxstacksize=maxstacksize))
    end
  else #No known analytic
    if save_timeseries
      timeseries = copy(timeseries)
      return(SDESolution(u,timeseries=timeseries,W=W,t=ts,maxstacksize=maxstacksize))
    else
      return(SDESolution(u,W=W,maxstacksize=maxstacksize))
    end
  end
end

const SDE_ADAPTIVEALGORITHMS = Set([:SRI,:SRIW1Optimized,:SRIVectorized,:SRAVectorized,:SRA1Optimized,:SRA])

function sde_determine_initΔt(u₀,t,abstol,reltol,internalnorm,f,g,order)
  d₀ = norm(u₀./(abstol+u₀*reltol),2)
  if typeof(u₀) <: Number
    f₀ = f(t,u₀)
    g₀ = 3g(t,u₀)
  else
    f₀ = similar(u₀)
    g₀ = similar(u₀)
    f(t,u₀,f₀)
    g(t,u₀,g₀); g₀.*=3
  end

  d₁ = norm(max(abs.(f₀.+g₀),abs.(f₀-g₀))./(abstol+u₀*reltol),2)
  if d₀ < 1e-5 || d₁ < 1e-5
    Δt₀ = 1e-6
  else
    Δt₀ = 0.01*(d₀/d₁)
  end
  u₁ = u₀ + Δt₀*f₀
  if typeof(u₀) <: Number
    f₁ = f(t+Δt₀,u₁)
    g₁ = 3g(t+Δt₀,u₁)
  else
    f₁ = similar(u₀)
    g₁ = similar(u₀)
    f(t,u₀,f₁)
    g(t,u₀,g₁); g₁.*=3
  end
  ΔgMax = max(abs.(g₀-g₁),abs.(g₀+g₁))
  d₂ = norm(max(abs.(f₁.-f₀.+ΔgMax),abs.(f₁.-f₀.-ΔgMax))./(abstol+u₀*reltol),2)/Δt₀
  if max(d₁,d₂)<=1e-15
    Δt₁ = max(1e-6,Δt₀*1e-3)
  else
    Δt₁ = 10.0^(-(2+log10(max(d₁,d₂)))/(order+.5))
  end
  Δt = min(100Δt₀,Δt₁)
end

function plan_sde(alg_hint,abstol,reltol,noisetype)
  :SRIW1Optimized
end
